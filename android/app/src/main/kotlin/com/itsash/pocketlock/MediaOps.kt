package com.itsash.pocketlock

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.SecureRandom

/** Metadata of one picked document. [mediaUri] is the MediaStore URI used to delete the original. */
data class Picked(
    val uri: Uri,
    val name: String,
    val mime: String,
    val size: Long,
    val mediaUri: Uri?,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "uri" to uri.toString(),
        "name" to name,
        "mime" to mime,
        "size" to size,
        "mediaUri" to mediaUri?.toString(),
    )
}

/** File and MediaStore work. All functions here block: call them off the main thread. */
class MediaOps(private val context: Context) {
    private val resolver get() = context.contentResolver
    private val stagingDir get() = File(context.cacheDir, STAGING).apply { mkdirs() }

    fun describe(uri: Uri): Picked {
        var name = "file"
        var size = -1L
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)
            ?.use { c ->
                if (c.moveToFirst()) {
                    c.getString(0)?.let { name = it }
                    if (!c.isNull(1)) size = c.getLong(1)
                }
            }
        val mime = resolver.getType(uri) ?: "application/octet-stream"
        return Picked(uri, name, mime, size, mediaUriFor(uri))
    }

    /** Maps a documents-provider URI (`image:123`) to its MediaStore URI, or null for other files. */
    private fun mediaUriFor(uri: Uri): Uri? {
        if (uri.authority != MEDIA_DOCUMENTS) return null
        val docId = runCatching { DocumentsContract.getDocumentId(uri) }.getOrNull() ?: return null
        val (type, id) = docId.split(":", limit = 2).let { it[0] to it.getOrNull(1)?.toLongOrNull() }
        if (id == null) return null
        val base = when (type) {
            "image" -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            "video" -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            else -> return null
        }
        return ContentUris.withAppendedId(base, id)
    }

    /** Copies a picked document into private cache and returns the file path. */
    fun stage(uri: Uri): String {
        val out = File(stagingDir, randomName())
        resolver.openInputStream(uri)?.use { input ->
            out.outputStream().use { input.copyTo(it, 64 * 1024) }
        } ?: throw IllegalStateException("Cannot open the file.")
        return out.absolutePath
    }

    fun wipeStaging() {
        File(context.cacheDir, STAGING).deleteRecursively()
    }

    /** JPEG thumbnail (longest side [THUMB_SIZE]) for an image or a video, or null. */
    fun thumbnail(path: String, mime: String): ByteArray? {
        val bitmap = when {
            mime.startsWith("image/") -> imageThumbnail(path)
            mime.startsWith("video/") -> videoThumbnail(path)
            else -> null
        } ?: return null
        val scaled = scaleDown(bitmap)
        val out = ByteArrayOutputStream()
        scaled.compress(Bitmap.CompressFormat.JPEG, 80, out)
        if (scaled !== bitmap) bitmap.recycle()
        scaled.recycle()
        return out.toByteArray()
    }

    private fun imageThumbnail(path: String): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= THUMB_SIZE) sample *= 2
        val bitmap = BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
            ?: return null
        val rotation = when (
            runCatching {
                ExifInterface(path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
            }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
        ) {
            ExifInterface.ORIENTATION_ROTATE_90 -> 90f
            ExifInterface.ORIENTATION_ROTATE_180 -> 180f
            ExifInterface.ORIENTATION_ROTATE_270 -> 270f
            else -> 0f
        }
        if (rotation == 0f) return bitmap
        val rotated = Bitmap.createBitmap(
            bitmap, 0, 0, bitmap.width, bitmap.height, Matrix().apply { postRotate(rotation) }, true,
        )
        if (rotated !== bitmap) bitmap.recycle()
        return rotated
    }

    private fun videoThumbnail(path: String): Bitmap? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
        } catch (e: Exception) {
            null
        } finally {
            retriever.release()
        }
    }

    private fun scaleDown(bitmap: Bitmap): Bitmap {
        val longest = maxOf(bitmap.width, bitmap.height)
        if (longest <= THUMB_SIZE) return bitmap
        val ratio = THUMB_SIZE.toFloat() / longest
        return Bitmap.createScaledBitmap(
            bitmap, (bitmap.width * ratio).toInt().coerceAtLeast(1), (bitmap.height * ratio).toInt().coerceAtLeast(1), true,
        )
    }

    /**
     * Copies a decrypted file into Pictures, Movies or Downloads (API 29+).
     * Throws [UnsupportedOperationException] below that.
     */
    fun export(path: String, name: String, mime: String, kind: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            throw UnsupportedOperationException("Export needs Android 10 or later.")
        }
        val (collection, folder) = when (kind) {
            "photo" -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI to "Pictures/Pocketlock"
            "video" -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI to "Movies/Pocketlock"
            else -> MediaStore.Downloads.EXTERNAL_CONTENT_URI to "Download/Pocketlock"
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, folder)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val target = resolver.insert(collection, values) ?: throw IllegalStateException("Cannot create the file.")
        try {
            resolver.openOutputStream(target)?.use { out ->
                File(path).inputStream().use { it.copyTo(out, 64 * 1024) }
            } ?: throw IllegalStateException("Cannot write the file.")
            resolver.update(target, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
        } catch (e: Exception) {
            resolver.delete(target, null, null)
            throw e
        }
    }

    private fun randomName(): String {
        val bytes = ByteArray(12).also { SecureRandom().nextBytes(it) }
        return bytes.joinToString("") { "%02x".format(it) }
    }

    companion object {
        private const val STAGING = "pl_staging"
        private const val MEDIA_DOCUMENTS = "com.android.providers.media.documents"
        private const val THUMB_SIZE = 360
    }
}

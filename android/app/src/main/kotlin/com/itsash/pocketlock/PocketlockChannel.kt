package com.itsash.pocketlock

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * MethodChannel `com.itsash.pocketlock/native`.
 *
 * Secrets cross this channel only as byte arrays and are never logged.
 */
class PocketlockChannel(private val activity: FragmentActivity, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    private val keys = KeystoreKeys(activity)
    private val media = MediaOps(activity)
    private val worker = Executors.newSingleThreadExecutor()
    private var pickResult: MethodChannel.Result? = null
    private var deleteResult: MethodChannel.Result? = null
    private var pendingDelete: List<Uri> = emptyList()
    private var permissionRetry = false

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setSecure" -> {
                val on = call.argument<Boolean>("on") ?: true
                val flag = WindowManager.LayoutParams.FLAG_SECURE
                if (on) activity.window.addFlags(flag) else activity.window.clearFlags(flag)
                result.success(null)
            }
            "biometricStatus" -> result.success(keys.biometricStatus())
            "biometricEnroll" -> {
                val vmk = call.argument<ByteArray>("vmk")
                if (vmk == null) result.error("bad_args", "Missing key.", null)
                else keys.enrollBiometric(vmk) { reply(result, it) }
            }
            "biometricUnlock" -> {
                val wrapped = call.argument<ByteArray>("wrapped")
                if (wrapped == null) result.error("bad_args", "Missing blob.", null)
                else keys.unlockBiometric(wrapped) { reply(result, it) }
            }
            "biometricRemove" -> {
                keys.removeBiometricKey()
                result.success(null)
            }
            "deviceSeal" -> guarded(result) { keys.seal(call.argument<ByteArray>("data")!!) }
            "deviceUnseal" -> guarded(result) { keys.unseal(call.argument<ByteArray>("data")!!) }
            "pick" -> pick(call.argument<Boolean>("mediaOnly") ?: false, result)
            "stage" -> background(result) { media.stage(Uri.parse(call.argument<String>("uri")!!)) }
            "wipeStaging" -> background(result) { media.wipeStaging() }
            "thumbnail" -> background(result) {
                media.thumbnail(call.argument<String>("path")!!, call.argument<String>("mime")!!)
            }
            "export" -> background(result) {
                media.export(
                    call.argument<String>("path")!!,
                    call.argument<String>("name")!!,
                    call.argument<String>("mime")!!,
                    call.argument<String>("kind")!!,
                )
            }
            "deleteOriginals" -> {
                val uris = call.argument<List<String>>("uris").orEmpty().map(Uri::parse)
                deleteOriginals(uris, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun reply(result: MethodChannel.Result, outcome: Result<ByteArray>) {
        outcome.fold(
            onSuccess = { result.success(it) },
            onFailure = {
                val code = (it as? KeystoreException)?.code ?: "failed"
                result.error(code, it.message ?: "Failed", null)
            },
        )
    }

    private fun guarded(result: MethodChannel.Result, block: () -> ByteArray) {
        try {
            result.success(block())
        } catch (e: KeystoreException) {
            result.error(e.code, e.message, null)
        } catch (e: Exception) {
            result.error("failed", e.message ?: "Failed", null)
        }
    }

    /** Runs [block] on the worker thread and answers on the main thread. */
    private fun background(result: MethodChannel.Result, block: () -> Any?) {
        worker.execute {
            val outcome = runCatching(block)
            activity.runOnUiThread {
                outcome.fold(
                    onSuccess = { result.success(it) },
                    onFailure = {
                        val code = if (it is UnsupportedOperationException) "unsupported" else "failed"
                        result.error(code, it.message ?: "Failed", null)
                    },
                )
            }
        }
    }

    private fun pick(mediaOnly: Boolean, result: MethodChannel.Result) {
        if (pickResult != null) {
            result.error("busy", "A picker is already open.", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            type = "*/*"
            if (mediaOnly) putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/*", "video/*"))
        }
        pickResult = result
        activity.startActivityForResult(intent, REQUEST_PICK)
    }

    private fun deleteOriginals(uris: List<Uri>, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            result.success("unsupported")
            return
        }
        if (uris.isEmpty()) {
            result.success("deleted")
            return
        }
        if (deleteResult != null) {
            result.error("busy", "Another request is open.", null)
            return
        }
        deleteResult = result
        pendingDelete = uris
        permissionRetry = false
        launchDelete()
    }

    private fun launchDelete() {
        try {
            val sender = MediaStore.createDeleteRequest(activity.contentResolver, pendingDelete).intentSender
            activity.startIntentSenderForResult(sender, REQUEST_DELETE, null, 0, 0, 0)
        } catch (e: SecurityException) {
            // The system wants read access to the gallery before it will ask the user.
            val permissions = mediaPermissions()
            if (!permissionRetry && permissions.any { !granted(it) }) {
                permissionRetry = true
                ActivityCompat.requestPermissions(activity, permissions, REQUEST_PERMISSION)
            } else {
                finishDelete("denied")
            }
        } catch (e: Exception) {
            finishDelete("failed")
        }
    }

    private fun mediaPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
        } else {
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }

    private fun granted(permission: String) =
        ContextCompat.checkSelfPermission(activity, permission) == PackageManager.PERMISSION_GRANTED

    private fun finishDelete(outcome: String) {
        deleteResult?.success(outcome)
        deleteResult = null
        pendingDelete = emptyList()
    }

    fun onPermissionResult(requestCode: Int, granted: Boolean) {
        if (requestCode != REQUEST_PERMISSION || deleteResult == null) return
        if (granted) launchDelete() else finishDelete("denied")
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        when (requestCode) {
            REQUEST_PICK -> {
                val result = pickResult ?: return
                pickResult = null
                if (resultCode != Activity.RESULT_OK || data == null) {
                    result.success(emptyList<Map<String, Any?>>())
                    return
                }
                val uris = buildList {
                    data.clipData?.let { clip -> for (i in 0 until clip.itemCount) add(clip.getItemAt(i).uri) }
                    data.data?.let { add(it) }
                }.distinct()
                background(result) { uris.map { media.describe(it).toMap() } }
            }
            REQUEST_DELETE -> finishDelete(if (resultCode == Activity.RESULT_OK) "deleted" else "denied")
        }
    }

    private companion object {
        const val CHANNEL = "com.itsash.pocketlock/native"
        const val REQUEST_PICK = 4201
        const val REQUEST_DELETE = 4202
        const val REQUEST_PERMISSION = 4203
    }
}

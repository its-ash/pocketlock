package com.itsash.pocketlock

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.os.Build
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Failure with a stable code that the Dart side maps to a message. */
class KeystoreException(val code: String, message: String) : Exception(message)

/**
 * Android Keystore keys.
 *
 * - Biometric key: AES-256-GCM, user authentication required for every use
 *   (BiometricPrompt + CryptoObject), invalidated when fingerprints change.
 *   It wraps the vault master key (VMK) for fingerprint unlock.
 * - Device key: AES-256-GCM, no user authentication. It seals the PIN-wrapped
 *   VMK so an offline copy of the vault file cannot be brute-forced off the
 *   phone.
 *
 * Wrapped layout: [iv length: 1 byte][iv][ciphertext + tag].
 */
class KeystoreKeys(private val activity: FragmentActivity) {
    private val keyStore: KeyStore = KeyStore.getInstance(PROVIDER).apply { load(null) }

    fun biometricStatus(): String {
        val result = BiometricManager.from(activity)
            .canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)
        return when (result) {
            BiometricManager.BIOMETRIC_SUCCESS -> "available"
            BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> "none_enrolled"
            else -> "unavailable"
        }
    }

    /** Creates a fresh biometric key and wraps [vmk] with it after a fingerprint check. */
    fun enrollBiometric(vmk: ByteArray, done: (Result<ByteArray>) -> Unit) {
        val cipher = try {
            createBiometricKey()
            Cipher.getInstance(TRANSFORMATION).apply { init(Cipher.ENCRYPT_MODE, secretKey(BIO_ALIAS)) }
        } catch (e: Exception) {
            vmk.fill(0)
            done(Result.failure(KeystoreException("failed", "Could not create the biometric key.")))
            return
        }
        authenticate(cipher, "Enable fingerprint unlock") { result ->
            val out = result.mapCatching { c -> pack(c.iv, c.doFinal(vmk)) }
            vmk.fill(0)
            if (out.isFailure) removeBiometricKey()
            done(out)
        }
    }

    fun unlockBiometric(wrapped: ByteArray, done: (Result<ByteArray>) -> Unit) {
        val cipher = try {
            val (iv, _) = unpack(wrapped)
            Cipher.getInstance(TRANSFORMATION).apply {
                init(Cipher.DECRYPT_MODE, secretKey(BIO_ALIAS), GCMParameterSpec(TAG_BITS, iv))
            }
        } catch (e: KeyPermanentlyInvalidatedException) {
            removeBiometricKey()
            done(Result.failure(KeystoreException("invalidated", "Biometrics changed.")))
            return
        } catch (e: Exception) {
            done(Result.failure(KeystoreException("invalidated", "Biometric key is unavailable.")))
            return
        }
        authenticate(cipher, "Unlock Pocketlock") { result ->
            done(result.mapCatching { c -> c.doFinal(unpack(wrapped).second) })
        }
    }

    fun removeBiometricKey() {
        if (keyStore.containsAlias(BIO_ALIAS)) keyStore.deleteEntry(BIO_ALIAS)
    }

    fun seal(plain: ByteArray): ByteArray {
        if (!keyStore.containsAlias(DEVICE_ALIAS)) createDeviceKey()
        val cipher = Cipher.getInstance(TRANSFORMATION).apply {
            init(Cipher.ENCRYPT_MODE, secretKey(DEVICE_ALIAS))
        }
        return pack(cipher.iv, cipher.doFinal(plain))
    }

    fun unseal(sealed: ByteArray): ByteArray {
        try {
            val (iv, body) = unpack(sealed)
            val cipher = Cipher.getInstance(TRANSFORMATION).apply {
                init(Cipher.DECRYPT_MODE, secretKey(DEVICE_ALIAS), GCMParameterSpec(TAG_BITS, iv))
            }
            return cipher.doFinal(body)
        } catch (e: Exception) {
            throw KeystoreException("device_key", "The device key could not open the vault.")
        }
    }

    private fun authenticate(cipher: Cipher, title: String, done: (Result<Cipher>) -> Unit) {
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                val c = result.cryptoObject?.cipher
                done(
                    if (c != null) Result.success(c)
                    else Result.failure(KeystoreException("failed", "No cipher returned."))
                )
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                val cancelled = errorCode == BiometricPrompt.ERROR_USER_CANCELED ||
                    errorCode == BiometricPrompt.ERROR_NEGATIVE_BUTTON ||
                    errorCode == BiometricPrompt.ERROR_CANCELED
                done(Result.failure(KeystoreException(if (cancelled) "cancelled" else "failed", errString.toString())))
            }
        }
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setNegativeButtonText("Use PIN")
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
            .setConfirmationRequired(false)
            .build()
        BiometricPrompt(activity, ContextCompat.getMainExecutor(activity), callback)
            .authenticate(info, BiometricPrompt.CryptoObject(cipher))
    }

    private fun createBiometricKey() {
        removeBiometricKey()
        val spec = KeyGenParameterSpec.Builder(
            BIO_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)
            .apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
                }
            }
            .build()
        generate(spec)
    }

    private fun createDeviceKey() {
        val spec = KeyGenParameterSpec.Builder(
            DEVICE_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build()
        generate(spec)
    }

    private fun generate(spec: KeyGenParameterSpec) {
        KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER).apply { init(spec) }.generateKey()
    }

    private fun secretKey(alias: String): SecretKey =
        (keyStore.getKey(alias, null) as? SecretKey) ?: throw KeystoreException("invalidated", "Missing key.")

    private fun pack(iv: ByteArray, body: ByteArray): ByteArray =
        byteArrayOf(iv.size.toByte()) + iv + body

    private fun unpack(blob: ByteArray): Pair<ByteArray, ByteArray> {
        val ivLength = blob[0].toInt() and 0xFF
        return blob.copyOfRange(1, 1 + ivLength) to blob.copyOfRange(1 + ivLength, blob.size)
    }

    private companion object {
        const val PROVIDER = "AndroidKeyStore"
        const val BIO_ALIAS = "pocketlock_biometric_v1"
        const val DEVICE_ALIAS = "pocketlock_device_v1"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val TAG_BITS = 128
    }
}

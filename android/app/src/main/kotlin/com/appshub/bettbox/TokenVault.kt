package com.appshub.bettbox

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 登录 token 的 Android 本地加密存储。
 *
 * 密文写在应用私有目录（files/token.vault），密钥由 Android Keystore 保管
 * （不可导出、不随备份迁移），避免 token 以明文形式留在 SharedPreferences 里
 * 被 adb 备份、云备份或 root 后直接读取。
 *
 * 任何异常都会向 Dart 侧返回错误，由调用方回退到原有 SharedPreferences 路径，
 * 保证登录态行为与改动前一致。
 */
class TokenVault(private val context: Context) {
    companion object {
        private const val CHANNEL = "appshub/token_vault"
        private const val KEY_ALIAS = "nexto_app_token_key"
        private const val FILE_NAME = "token.vault"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_BITS = 128
        private const val IV_BYTES = 12
    }

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "read" -> result.success(read())
                    "write" -> {
                        val value = call.argument<String>("value")
                        if (value.isNullOrEmpty()) {
                            result.error("bad_args", "value is empty", null)
                        } else {
                            write(value)
                            result.success(true)
                        }
                    }
                    "clear" -> {
                        clear()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Throwable) {
                result.error("vault_error", e.message ?: e.javaClass.simpleName, null)
            }
        }
    }

    private fun vaultFile() = File(context.filesDir, FILE_NAME)

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        val existing = keyStore.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry
        if (existing != null) {
            return existing.secretKey
        }
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            ANDROID_KEYSTORE,
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private fun read(): String? {
        val file = vaultFile()
        if (!file.exists()) {
            return null
        }
        return try {
            val bytes = file.readBytes()
            if (bytes.size <= IV_BYTES) {
                file.delete()
                return null
            }
            val iv = bytes.copyOfRange(0, IV_BYTES)
            val cipherText = bytes.copyOfRange(IV_BYTES, bytes.size)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                secretKey(),
                GCMParameterSpec(GCM_TAG_BITS, iv),
            )
            String(cipher.doFinal(cipherText), Charsets.UTF_8)
        } catch (e: Throwable) {
            // 换机恢复 / 清数据后 Keystore 密钥不在，旧密文已不可解：
            // 清掉它并按“未登录”处理，用户重新登录即可，不阻塞启动。
            file.delete()
            null
        }
    }

    private fun write(value: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val cipherText = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val payload = cipher.iv.copyOfRange(0, IV_BYTES) + cipherText
        val target = vaultFile()
        val temp = File(target.parentFile, "$FILE_NAME.tmp")
        temp.writeBytes(payload)
        if (!temp.renameTo(target)) {
            target.delete()
            if (!temp.renameTo(target)) {
                temp.delete()
                throw IllegalStateException("rename vault file failed")
            }
        }
    }

    private fun clear() {
        vaultFile().delete()
    }
}

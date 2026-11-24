package dev.zcodeapp.zcode_companion

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 图片保存到系统相册（2026-11-24 图片查看器下载按钮）：
 * - API 29+：MediaStore.Images 插入（Pictures/ZCodePocket，无需权限）；
 * - API < 29：应用外部私有 Pictures 目录（无需权限，相册可扫描）。
 */
object MediaSavePlugin {
    private const val CHANNEL = "companion/media_save"

    fun bind(flutterEngine: FlutterEngine, context: Context) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveImage" -> {
                        try {
                            val bytes = call.argument<ByteArray>("bytes")
                            val name = call.argument<String>("name") ?: "zcode_image"
                            val mime = call.argument<String>("mime") ?: "image/jpeg"
                            if (bytes == null || bytes.isEmpty()) {
                                result.error("empty", "empty image bytes", null)
                                return@setMethodCallHandler
                            }
                            result.success(mapOf("path" to save(context, name, mime, bytes)))
                        } catch (e: Throwable) {
                            result.error("save_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun save(context: Context, name: String, mime: String, bytes: ByteArray): String {
        val ext = when {
            mime.contains("png") -> "png"
            mime.contains("gif") -> "gif"
            mime.contains("webp") -> "webp"
            else -> "jpg"
        }
        val fileName = if (name.contains('.')) name else "$name.$ext"
        if (Build.VERSION.SDK_INT >= 29) {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, fileName)
                put(MediaStore.Images.Media.MIME_TYPE, mime)
                put(
                    MediaStore.Images.Media.RELATIVE_PATH,
                    Environment.DIRECTORY_PICTURES + "/ZCodePocket",
                )
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val resolver = context.contentResolver
            val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("MediaStore insert failed")
            resolver.openOutputStream(uri)?.use { it.write(bytes) }
                ?: throw IllegalStateException("openOutputStream failed")
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return uri.toString()
        }
        val dir = File(context.getExternalFilesDir(Environment.DIRECTORY_PICTURES), "ZCodePocket")
        dir.mkdirs()
        val file = File(dir, fileName)
        file.writeBytes(bytes)
        return file.absolutePath
    }
}

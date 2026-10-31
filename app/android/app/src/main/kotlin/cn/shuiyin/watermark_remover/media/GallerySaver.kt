package cn.shuiyin.watermark_remover.media

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.FileInputStream
import java.io.IOException

/**
 * 把结果写进系统相册（Pictures/水印工坊）。
 *
 * 主路径是 Android 10（Q）及以上：MediaStore + RELATIVE_PATH，**不需要任何存储权限**，已实测。
 * 更老的系统走 EXTERNAL_CONTENT_URI 分支，但那条路要先拿 WRITE_EXTERNAL_STORAGE 的运行时授权，
 * 这一版没实现 —— `copyInto` 会把 SecurityException 翻译成一句人话提示（用户至少知道
 * 是系统版本的问题，而不是 App 坏了）。⚠ 那条分支**从未在 Android 10 以下真机验证过**。
 */
object GallerySaver {
    private const val ALBUM = "水印工坊"

    fun save(context: Context, sourcePath: String, displayName: String): String {
        val resolver = context.contentResolver
        val isQ = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            if (isQ) {
                put(
                    MediaStore.Images.Media.RELATIVE_PATH,
                    "${Environment.DIRECTORY_PICTURES}/$ALBUM",
                )
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
        }

        val collection = if (isQ) {
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }

        return copyInto(context, collection, values, sourcePath, isQ)
    }

    /**
     * 视频版。和图片分开写，只有三处不同：集合（Video）、MIME、相对路径（Movies）。
     *
     * 注意 `IS_PENDING` 的用法和图片一样：先插一条 pending 记录再灌数据，
     * 灌完才置 0 —— 否则相册里会闪出一条 0 字节的坏视频，而且没灌完就被相册扫描到。
     */
    fun saveVideo(context: Context, sourcePath: String, displayName: String): String {
        val isQ = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            if (isQ) {
                put(
                    MediaStore.Video.Media.RELATIVE_PATH,
                    "${Environment.DIRECTORY_MOVIES}/$ALBUM",
                )
                put(MediaStore.Video.Media.IS_PENDING, 1)
            }
        }

        val collection = if (isQ) {
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        }

        return copyInto(context, collection, values, sourcePath, isQ)
    }

    private fun copyInto(
        context: Context,
        collection: android.net.Uri,
        values: ContentValues,
        sourcePath: String,
        isQ: Boolean,
    ): String {
        val resolver = context.contentResolver
        val uri = try {
            resolver.insert(collection, values)
        } catch (e: SecurityException) {
            // Android 10 以下往 MediaStore 写必须持有 WRITE_EXTERNAL_STORAGE，
            // 而这一版没做运行时授权（见类注释）。系统抛的是
            // 「Permission Denial: writing com.android.providers.media...」，
            // 用户看到只会以为 App 坏了 —— 翻成人话。
            throw IOException(
                "这台手机是 Android 10 以下，保存到相册需要存储权限，当前版本还没支持。" +
                    "可以先用系统截图保存，或升级系统后再试。",
                e,
            )
        } ?: throw IllegalStateException("MediaStore 插入失败")

        try {
            resolver.openOutputStream(uri)?.use { out ->
                FileInputStream(sourcePath).use { input -> input.copyTo(out) }
            } ?: throw IllegalStateException("拿不到输出流：$uri")
        } catch (e: Throwable) {
            // 失败要把半成品删掉，否则相册里会留一条 0 字节记录
            resolver.delete(uri, null, null)
            throw e
        }

        if (isQ) {
            val done = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            resolver.update(uri, done, null, null)
        }
        return uri.toString()
    }
}

package cn.shuiyin.watermark_remover.media

/**
 * 申请「写外部存储」权限。
 *
 * 为什么要绕一层接口：`requestPermissions` 只能在 Activity 上调用，而
 * [MediaBridge] 只拿得到 applicationContext（它要活过 Activity 重建）。
 * 让 MainActivity 实现这个接口再塞进来，比在桥里强转 Context 到 Activity 稳 ——
 * 强转在 `cleanUpFlutterEngine` 之后、或 Activity 已销毁时会抛 ClassCastException。
 *
 * **只有 API ≤ 28 才会真的弹窗**：Android 10 起插入 MediaStore 不需要任何权限，
 * 实现方会直接回 true。
 */
interface WritePermissionDelegate {
    /**
     * @param onResult 结果回到**主线程**。已授权时同步回调。
     */
    fun ensureWriteStorage(onResult: (Boolean) -> Unit)
}

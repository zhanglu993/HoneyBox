package com.honeygui.honeybox

import android.app.Activity
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/** Copies app-private captures or verified downloads to SAF with bounded memory. */
class CaptureFileExporter(private val activity: Activity) {
    private val requestCode = 64017
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var source: File? = null

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "export") { result.notImplemented(); return }
        if (pending != null) { result.error("busy", "另一个文件正在导出", null); return }
        try {
            val file = File(requireNotNull(call.argument<String>("path"))).canonicalFile
            val root = File(activity.applicationInfo.dataDir).canonicalFile
            require(file.isFile && file.toPath().startsWith(root.toPath())) { "无效的采集文件" }
            val requestedName = call.argument<String>("fileName")
            val displayName = requestedName?.replace(Regex("[\\\\/\\p{Cntrl}]"), "_")
                ?.take(160)?.takeIf { it.isNotBlank() && it != "." && it != ".." }
                ?: "ble_${file.parentFile!!.name}.jsonl"
            source = file
            pending = result
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "application/octet-stream"
                putExtra(Intent.EXTRA_TITLE, displayName)
            }
            activity.startActivityForResult(intent, requestCode)
        } catch (e: Exception) {
            pending = null; source = null
            result.error("export_failed", e.message, null)
        }
    }

    fun onActivityResult(code: Int, resultCode: Int, data: Intent?): Boolean {
        if (code != requestCode) return false
        val result = pending ?: return true
        val file = source
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || file == null) {
            pending = null; source = null; result.success(null); return true
        }
        executor.execute {
            var failure: String? = null
            try {
                file.inputStream().use { input ->
                    requireNotNull(activity.contentResolver.openOutputStream(uri, "wt")).use { output ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            if (Thread.currentThread().isInterrupted) throw InterruptedException("导出已取消")
                            val length = input.read(buffer)
                            if (length < 0) break
                            output.write(buffer, 0, length)
                        }
                        output.flush()
                    }
                }
            } catch (e: Exception) { failure = e.message ?: "文件导出失败" }
            main.post {
                if (pending === result) {
                    pending = null; source = null
                    if (failure == null) result.success(uri.toString())
                    else result.error("export_failed", failure, null)
                }
            }
        }
        return true
    }

    fun close() {
        executor.shutdownNow()
        pending?.error("cancelled", "页面已关闭，导出已取消", null)
        pending = null; source = null
    }
}

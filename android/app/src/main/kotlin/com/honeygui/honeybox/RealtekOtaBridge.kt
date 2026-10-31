package com.honeygui.honeybox

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.realsil.sdk.core.RtkConfigure
import com.realsil.sdk.core.RtkCore
import com.realsil.sdk.dfu.DfuConstants
import com.realsil.sdk.dfu.RtkDfu
import com.realsil.sdk.dfu.model.DfuConfig
import com.realsil.sdk.dfu.model.DfuProgressInfo
import com.realsil.sdk.dfu.model.OtaDeviceInfo
import com.realsil.sdk.dfu.model.Throughput
import com.realsil.sdk.dfu.utils.ConnectParams
import com.realsil.sdk.dfu.utils.DfuAdapter
import com.realsil.sdk.dfu.utils.GattDfuAdapter
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

class RealtekOtaBridge(context: Context, messenger: BinaryMessenger) {
    private val app = context.applicationContext
    private val handler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var adapter: GattDfuAdapter? = null
    private var address = ""
    private var path = ""
    private var started = false
    private var processing = false
    private var prepared = false
    private var target: OtaDeviceInfo? = null

    init {
        EventChannel(messenger, "honeybox/realtek-ota/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
            override fun onCancel(arguments: Any?) { sink = null }
        })
        MethodChannel(messenger, "honeybox/realtek-ota").setMethodCallHandler { call, result ->
            when (call.method) {
                "prepare" -> {
                    val mac = call.argument<String>("address")
                    if (started || mac.isNullOrBlank()) {
                        result.error("invalid", "设备地址无效，或已有连接", null)
                    } else {
                        try {
                            address = mac
                            target = null
                            started = true
                            processing = false
                            prepared = false
                            RtkCore.initialize(app, RtkConfigure.Builder().debugEnabled(false).printLog(false).build())
                            RtkDfu.initialize(app, false)
                            adapter = GattDfuAdapter.getInstance(app)
                            if (adapter?.initialize(callback) != true) {
                                started = false
                                result.error("init", "初始化 Realtek OTA 失败", null)
                            } else result.success(null)
                        } catch (e: Exception) {
                            started = false
                            result.error("init", e.message, null)
                        }
                    }
                }
                "start" -> {
                    val file = call.argument<String>("path")
                    if (!started || !prepared || processing || file.isNullOrBlank() || !File(file).isFile) {
                        result.error("invalid", "设备尚未就绪或固件不可读", null)
                    } else {
                        path = file
                        processing = true
                        val config = DfuConfig().apply {
                            setFilePath(path)
                            setAddress(this@RealtekOtaBridge.address)
                            setSectionSizeCheckEnabled(false)
                            setVersionCheckEnabled(false)
                        }
                        if (adapter?.startOtaProcedure(config, target, true) != true) {
                            emit("Realtek SDK 未能启动升级", true)
                            result.error("start", "Realtek SDK 未能启动升级", null)
                        } else result.success(null)
                    }
                }
                "close" -> { if (!processing) { adapter?.destroy(); adapter = null; started = false; prepared = false }; result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    private fun emit(message: String, done: Boolean = false, progress: Int? = null, ready: Boolean = false) {
        if (done) { started = false; processing = false; prepared = false }
        handler.post { sink?.success(mapOf("message" to message, "done" to done, "progress" to progress, "ready" to ready)) }
    }

    private val callback = object : DfuAdapter.DfuHelperCallback() {
        override fun onStateChanged(state: Int) {
            if (!started) return
            when (state) {
                DfuAdapter.STATE_INIT_OK -> {
                    emit("正在连接设备")
                    if (adapter?.connectDevice(ConnectParams.Builder().address(address).reconnectTimes(3).build()) != true)
                        emit("无法发起设备连接", true)
                }
                DfuAdapter.STATE_PREPARED -> {
                    if (!processing) { prepared = true; emit("设备已连接，请选择匹配的固件", ready = true) }
                }
                DfuAdapter.STATE_CONNECT_FAILED -> emit("设备连接失败", true)
                DfuAdapter.STATE_DISCONNECTED -> if (!processing) emit("设备已断开", true)
            }
        }
        override fun onTargetInfoChanged(info: OtaDeviceInfo?) { target = info }
        override fun onError(type: Int, code: Int) { if (started) emit("升级失败：类型 $type，错误码 $code", true) }
        override fun onProgressChanged(info: DfuProgressInfo?) { if (started && info != null) emit("正在传输固件", progress = info.progress) }
        override fun onProcessStateChanged(state: Int, throughput: Throughput?) {
            if (!started) return
            when (state) {
                DfuConstants.PROGRESS_ACTIVE_IMAGE_AND_RESET -> emit("正在激活固件")
                DfuConstants.PROGRESS_COMPLETED, DfuConstants.PROGRESS_IMAGE_ACTIVE_SUCCESS -> emit("SDK 报告升级完成，请核对设备版本", true, 100)
                DfuConstants.PROGRESS_ABORTED -> emit("升级已中止", true)
                DfuConstants.PROGRESS_PROCESSING_ERROR -> emit("升级失败，请查看错误信息", true)
            }
        }
    }
}

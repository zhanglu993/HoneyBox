package com.honeygui.honeybox

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.realsil.sdk.core.RtkConfigure
import com.realsil.sdk.core.RtkCore
import com.realsil.sdk.dfu.DfuConstants
import com.realsil.sdk.dfu.RtkDfu
import com.realsil.sdk.dfu.image.FirmwareLoaderX
import com.realsil.sdk.dfu.image.LoadParams
import com.realsil.sdk.dfu.exception.LoadFileException
import com.realsil.sdk.dfu.model.DfuBufferCheckConfig
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
import java.util.UUID

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
    private var generation = 0L
    private var sessionId = ""
    private var outcome: String? = null

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
                            cleanup()
                            val current = ++generation
                            sessionId = call.argument<String>("sessionId")?.takeIf { it.isNotBlank() } ?: UUID.randomUUID().toString()
                            outcome = null
                            address = mac
                            target = null
                            started = true
                            processing = false
                            prepared = false
                            RtkCore.initialize(app, RtkConfigure.Builder().debugEnabled(false).printLog(false).build())
                            RtkDfu.initialize(app, false)
                            adapter = GattDfuAdapter.getInstance(app)
                            if (adapter?.initialize(callback(current)) != true) {
                                cleanup()
                                result.error("init", "初始化 Realtek OTA 失败", null)
                            } else result.success(null)
                        } catch (e: Exception) {
                            cleanup()
                            result.error("init", e.message, null)
                        }
                    }
                }
                "deviceCapabilities" -> {
                    val info = target
                    val versions = info?.imageVersionInfos
                    val image = if (versions?.size == 1) versions[0] else null
                    result.success(mapOf(
                        "icType" to info?.icType?.takeIf { it > 0 },
                        "imageId" to image?.imageId?.takeIf { it > 0 },
                        "currentVersion" to image?.version?.takeIf { it >= 0 },
                        "capacity" to image?.sectionSize?.takeIf { it > 0 },
                    ))
                }
                "inspectFirmware" -> {
                    val file = call.argument<String>("path")
                    if (file.isNullOrBlank() || !File(file).isFile || File(file).length() == 0L) {
                        result.success(mapOf("errorCode" to "invalid_file"))
                    } else {
                        try {
                            val params = LoadParams.Builder().with(app).setFilePath(file)
                                .setOtaDeviceInfo(target)
                                .setIcCheckEnabled(true).setVersionCheckEnabled(true)
                                .setSectionSizeCheckEnabled(true).setIgnoreException(false).build()
                            val info = FirmwareLoaderX.loadImageBinInfo(params)
                            if (info == null) {
                                result.success(mapOf("errorCode" to "no_result"))
                            } else {
                                val streams = info.subBinInputStreams ?: emptyList()
                                val subFiles = info.subFileInfos ?: emptyList()
                                val images = streams.map { stream ->
                                    val matching = subFiles.filter { it.imageId == stream.imageId && it.binId == stream.binId }
                                    mapOf("imageId" to stream.imageId, "binId" to stream.binId,
                                        "offset" to if (!info.isPackFile) 0L else matching.singleOrNull()?.c,
                                        "size" to stream.imageSize, "version" to stream.imageVersion,
                                        "icType" to stream.icType)
                                }
                                // Status and updateEnabled default to success even without a parsed header.
                                // No matching SDK fixture has validated header or section/version checks yet.
                                result.success(mapOf("status" to info.status, "updateEnabled" to info.updateEnabled,
                                    "icType" to info.icType, "version" to info.version,
                                    "type" to if (info.isPackFile) "Realtek pack" else "Realtek single",
                                    "images" to images,
                                    "subFiles" to subFiles.map { mapOf("imageId" to it.imageId,
                                        "binId" to it.binId, "offset" to it.c, "size" to it.size,
                                        "version" to it.imageVersion) },
                                    "formatVerified" to false,
                                    "capacityCheckAvailable" to false, "versionCheckAvailable" to false,
                                    "sdkCapacityCheckOption" to true, "sdkVersionCheckOption" to true))
                                streams.forEach { try { it.close() } catch (_: Exception) { } }
                            }
                        } catch (e: LoadFileException) {
                            result.success(mapOf("errorCode" to e.errCode, "errorType" to e.errType,
                                "message" to e.message))
                        } catch (e: Exception) {
                            result.success(mapOf("exception" to e.javaClass.simpleName, "message" to e.message))
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
                        try {
                            val config = DfuConfig().apply {
                                setFilePath(path)
                                setAddress(this@RealtekOtaBridge.address)
                                setSectionSizeCheckEnabled(false)
                                setVersionCheckEnabled(false)
                                // DFU's separate GATT connection requests MTU 256; the helper callback
                                // does not expose its negotiated MTU. Limit payload to (256 - 3) / 16 * 16.
                                // AAR javap: m.d.d passes the 0x09 MTU minus 3 to j.c.a;
                                // CUSTOMIZED returns preferredMtuSize unchanged (it does not take min).
                                setBufferCheckConfig(DfuBufferCheckConfig.Builder()
                                    .mtuUpdateMechanism(DfuBufferCheckConfig.BUFFER_CHECK_MTU_UPDATE_MECHANISM_CUSTOMIZED)
                                    .preferredMtuSize((256 - 3) / 16 * 16)
                                    .build())
                            }
                            if (adapter?.startOtaProcedure(config, target, true) != true) {
                                emit(generation, "Realtek SDK 未能启动升级", done = true, newOutcome = "failed")
                                result.error("start", "Realtek SDK 未能启动升级", null)
                            } else result.success(null)
                        } catch (e: Exception) {
                            emit(generation, "Realtek SDK 启动异常", done = true, newOutcome = "failed")
                            result.error("start", e.message, null)
                        }
                    }
                }
                "close" -> {
                    if (processing) result.error("busy", "升级进行中，无法关闭会话", null)
                    else { generation++; cleanup(); result.success(null) }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Release only after terminal state; never imply an in-flight write was canceled. */
    private fun cleanup() {
        val previous = adapter
        adapter = null
        started = false
        processing = false
        prepared = false
        target = null
        try { previous?.destroy() } catch (_: Exception) { }
    }

    private fun emit(
        current: Long,
        message: String,
        done: Boolean = false,
        progress: Int? = null,
        ready: Boolean = false,
        newOutcome: String? = null,
        errorType: Int? = null,
        errorCode: Int? = null,
    ) {
        if (current != generation) return
        // First terminal outcome wins; a later detailed error may enrich a failure.
        if (newOutcome != null && outcome != null && outcome != newOutcome) return
        if (done) {
            if (outcome == null) outcome = newOutcome
            started = false
            processing = false
            prepared = false
        }
        val event = mapOf(
            "sessionId" to sessionId, "message" to message, "done" to done,
            "progress" to progress, "ready" to ready, "outcome" to outcome,
            "errorType" to errorType, "errorCode" to errorCode,
        )
        handler.post { if (current == generation) sink?.success(event) }
    }

    /** SDK callbacks can be on arbitrary threads; serialize state transitions on main. */
    private fun callback(current: Long) = object : DfuAdapter.DfuHelperCallback() {
        private fun dispatch(action: () -> Unit) {
            handler.post { if (current == generation) action() }
        }

        override fun onStateChanged(state: Int) = dispatch {
            if (started) when (state) {
                DfuAdapter.STATE_INIT_OK -> {
                    emit(current, "正在连接设备")
                    val connected = try {
                        adapter?.connectDevice(ConnectParams.Builder().address(address).reconnectTimes(3).build()) == true
                    } catch (_: Exception) { false }
                    if (!connected)
                        emit(current, "无法发起设备连接", done = true, newOutcome = "failed")
                }
                DfuAdapter.STATE_PREPARED -> if (!processing) {
                    prepared = true
                    emit(current, "设备已连接，请选择匹配的固件", ready = true)
                }
                DfuAdapter.STATE_CONNECT_FAILED -> emit(current, "设备连接失败", done = true, newOutcome = "failed")
                DfuAdapter.STATE_DISCONNECTED -> if (!processing) emit(current, "设备已断开", done = true, newOutcome = "failed")
            }
        }
        override fun onTargetInfoChanged(info: OtaDeviceInfo?) = dispatch {
            if (started) target = info
        }
        override fun onError(type: Int, code: Int) = dispatch {
            if (started || outcome == "failed")
                emit(current, "升级失败：类型 $type，错误码 $code", done = true,
                    newOutcome = "failed", errorType = type, errorCode = code)
        }
        override fun onProgressChanged(info: DfuProgressInfo?) = dispatch {
            if (started && info != null) emit(current, "正在传输固件", progress = info.progress)
        }
        override fun onProcessStateChanged(state: Int, throughput: Throughput?) = dispatch {
            if (started) when (state) {
                DfuConstants.PROGRESS_ACTIVE_IMAGE_AND_RESET -> emit(current, "正在激活固件")
                DfuConstants.PROGRESS_COMPLETED, DfuConstants.PROGRESS_IMAGE_ACTIVE_SUCCESS ->
                    emit(current, "SDK 报告升级完成，设备版本待核验", done = true, progress = 100,
                        newOutcome = "pendingVerification")
                DfuConstants.PROGRESS_ABORTED -> emit(current, "升级已中止", done = true, newOutcome = "canceled")
                DfuConstants.PROGRESS_PROCESSING_ERROR -> emit(current, "升级失败，请查看错误信息", done = true, newOutcome = "failed")
            }
        }
    }
}

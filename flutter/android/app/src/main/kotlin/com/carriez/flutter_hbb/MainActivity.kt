package com.carriez.flutter_hbb

/**
 * Handle events from flutter
 * Request MediaProjection permission
 *
 * Inspired by [droidVNC-NG] https://github.com/bk138/droidVNC-NG
 */

import ffi.FFI

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.ClipboardManager
import android.os.Bundle
import android.os.Build
import android.os.IBinder
import android.util.Log
import android.view.WindowManager
import android.media.MediaCodecInfo
import android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface
import android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar
import android.media.MediaCodecList
import android.media.MediaFormat
import android.util.DisplayMetrics
import androidx.annotation.RequiresApi
import org.json.JSONArray
import org.json.JSONObject
import com.hjq.permissions.XXPermissions
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread


class MainActivity : FlutterActivity() {
    companion object {
        var flutterMethodChannel: MethodChannel? = null
        private var _rdClipboardManager: RdClipboardManager? = null
        val rdClipboardManager: RdClipboardManager?
            get() = _rdClipboardManager;
    }

    private val channelTag = "mChannel"
    private val logTag = "mMainActivity"
    private var mainService: MainService? = null

    private var isAudioStart = false
    private val audioRecordHandle = AudioRecordHandle(this, { false }, { isAudioStart })

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (MainService.isReady) {
            Intent(activity, MainService::class.java).also {
                bindService(it, serviceConnection, Context.BIND_AUTO_CREATE)
            }
        }
        flutterMethodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelTag
        )
        initFlutterChannel(flutterMethodChannel!!)
        // 키오스크관리: 우리 네이티브 채널 (device-owner 리부트 등)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "azit/native")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "reboot" -> { azitReboot(); result.success(true) }
                    "set_volume" -> { azitSetVolume(call.argument<Int>("percent") ?: 50); result.success(true) }
                    "save_creds" -> {
                        getSharedPreferences("azit_agent", Context.MODE_PRIVATE).edit()
                            .putString("device_id", call.argument<String>("deviceId"))
                            .putString("agent_key", call.argument<String>("agentKey"))
                            .apply()
                        result.success(true)
                    }
                    "get_creds" -> {
                        val p = getSharedPreferences("azit_agent", Context.MODE_PRIVATE)
                        result.success(mapOf(
                            "deviceId" to (p.getString("device_id", "") ?: ""),
                            "agentKey" to (p.getString("agent_key", "") ?: "")
                        ))
                    }
                    else -> result.notImplemented()
                }
            }
        thread {
            try {
                setCodecInfo()
            } catch (e: Exception) {
                Log.e("MainActivity", "Failed to setCodecInfo: ${e.message}", e)
            }
        }
    }

    // 키오스크관리: device-owner면 기기 리부트
    private fun azitReboot() {
        try {
            val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as android.app.admin.DevicePolicyManager
            val admin = ComponentName(this, AzitAdminReceiver::class.java)
            if (dpm.isDeviceOwnerApp(packageName)) {
                dpm.reboot(admin)
            } else {
                Log.w(logTag, "리부트 요청: device-owner 아님 — 무시됨")
            }
        } catch (e: Exception) {
            Log.e(logTag, "리부트 실패: ${e.message}")
        }
    }

    override fun onResume() {
        super.onResume()
        // 키오스크 무음 모드: 부팅 자동실행이면 포그라운드로 올라올 때마다 즉시 뒤로 보낸다.
        // 미디어프로젝션 요청 등으로 몇 번을 앞으로 나와도 매번 백그라운드 → UI가 절대 머무르지 않음.
        if (azitSilentBoot) {
            window.decorView.postDelayed({
                if (azitSilentBoot) {
                    try { moveTaskToBack(true) } catch (_: Exception) {}
                }
            }, 150)
        }
        val inputPer = InputService.isOpen
        activity.runOnUiThread {
            flutterMethodChannel?.invokeMethod(
                "on_state_changed",
                mapOf("name" to "input", "value" to inputPer.toString())
            )
        }
    }

    private fun requestMediaProjection() {
        val intent = Intent(this, PermissionRequestTransparentActivity::class.java).apply {
            action = ACT_REQUEST_MEDIA_PROJECTION
        }
        startActivityForResult(intent, REQ_INVOKE_PERMISSION_ACTIVITY_MEDIA_PROJECTION)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_INVOKE_PERMISSION_ACTIVITY_MEDIA_PROJECTION && resultCode == RES_FAILED) {
            flutterMethodChannel?.invokeMethod("on_media_projection_canceled", null)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (_rdClipboardManager == null) {
            _rdClipboardManager = RdClipboardManager(getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager)
            FFI.setClipboardManager(_rdClipboardManager!!)
        }
        azitSetupKiosk()
        // 키오스크: 부팅 자동실행이면 UI를 띄우지 않고 백그라운드로.
        // 실제 백그라운드 처리는 onResume에서 — 포그라운드로 올라올 때마다 매번 뒤로 보내므로
        // 미디어프로젝션 요청 등으로 여러 번 앞으로 나와도 절대 머무르지 않는다.
        // (에이전트/서비스는 Flutter 백그라운드에서 계속 동작. 사용자가 직접 앱을 열 때만 UI 표시)
        azitSilentBoot = intent?.getBooleanExtra("azit_silent_boot", false) == true
    }

    // 부팅 무음 모드 플래그(사용자가 직접 앱을 열거나 화면을 만지면 해제 → 더 이상 뒤로 안 보냄)
    private var azitSilentBoot = false

    override fun onUserInteraction() {
        super.onUserInteraction()
        // 사용자가 화면을 만지면(직접 사용 의도) 무음 백그라운드 중단
        azitSilentBoot = false
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // 런처/알림 등으로 직접 다시 열면(무음 플래그 없는 인텐트) 무음 모드 해제 → UI 정상 표시
        if (intent.getBooleanExtra("azit_silent_boot", false) != true) {
            azitSilentBoot = false
        }
    }

    // 키오스크관리: device-owner면 잠금(홈·뒤로·최근 막기) — 다른 사용자가 못 빠져나감
    private fun azitSetupKiosk() {
        try {
            val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as android.app.admin.DevicePolicyManager
            if (!dpm.isDeviceOwnerApp(packageName)) return
            val admin = ComponentName(this, AzitAdminReceiver::class.java)
            // 음량 고정: 외부 사용자가 하드웨어 버튼으로 못 바꿈 (조절은 우리 set_volume 명령으로만)
            dpm.addUserRestriction(admin, android.os.UserManager.DISALLOW_ADJUST_VOLUME)
            Log.i(logTag, "음량 고정 적용 (백그라운드 에이전트 모드)")
        } catch (e: Exception) {
            Log.e(logTag, "키오스크 셋업 실패: ${e.message}")
        }
    }

    // 음량 설정(0~100). device-owner 제한을 잠시 풀고 적용 후 복원 → 앱 내에서만 조절 가능
    private fun azitSetVolume(percent: Int) {
        try {
            val am = getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
            val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as android.app.admin.DevicePolicyManager
            val isOwner = dpm.isDeviceOwnerApp(packageName)
            val admin = ComponentName(this, AzitAdminReceiver::class.java)
            if (isOwner) dpm.clearUserRestriction(admin, android.os.UserManager.DISALLOW_ADJUST_VOLUME)
            val max = am.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC)
            val v = (percent.coerceIn(0, 100) * max / 100)
            am.setStreamVolume(android.media.AudioManager.STREAM_MUSIC, v, 0)
            if (isOwner) dpm.addUserRestriction(admin, android.os.UserManager.DISALLOW_ADJUST_VOLUME)
        } catch (e: Exception) {
            Log.e(logTag, "음량 설정 실패: ${e.message}")
        }
    }

    // 하드웨어 음량 버튼 차단 (앱이 항상 포그라운드인 키오스크에서 외부 조작 방지)
    override fun onKeyDown(keyCode: Int, event: android.view.KeyEvent?): Boolean {
        if (keyCode == android.view.KeyEvent.KEYCODE_VOLUME_UP ||
            keyCode == android.view.KeyEvent.KEYCODE_VOLUME_DOWN) {
            return true // consume
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onDestroy() {
        Log.e(logTag, "onDestroy")
        mainService?.let {
            unbindService(serviceConnection)
        }
        super.onDestroy()
    }

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            Log.d(logTag, "onServiceConnected")
            val binder = service as MainService.LocalBinder
            mainService = binder.getService()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            Log.d(logTag, "onServiceDisconnected")
            mainService = null
        }
    }

    private fun initFlutterChannel(flutterMethodChannel: MethodChannel) {
        flutterMethodChannel.setMethodCallHandler { call, result ->
            // make sure result will be invoked, otherwise flutter will await forever
            when (call.method) {
                "init_service" -> {
                    Intent(activity, MainService::class.java).also {
                        bindService(it, serviceConnection, Context.BIND_AUTO_CREATE)
                    }
                    if (MainService.isReady) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    requestMediaProjection()
                    result.success(true)
                }
                "start_capture" -> {
                    mainService?.let {
                        result.success(it.startCapture())
                    } ?: let {
                        result.success(false)
                    }
                }
                "stop_service" -> {
                    Log.d(logTag, "Stop service")
                    mainService?.let {
                        it.destroy()
                        result.success(true)
                    } ?: let {
                        result.success(false)
                    }
                }
                "check_permission" -> {
                    if (call.arguments is String) {
                        result.success(XXPermissions.isGranted(context, call.arguments as String))
                    } else {
                        result.success(false)
                    }
                }
                "request_permission" -> {
                    if (call.arguments is String) {
                        requestPermission(context, call.arguments as String)
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                START_ACTION -> {
                    if (call.arguments is String) {
                        startAction(context, call.arguments as String)
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "shizuku_available" -> {
                    // 기기에 Shizuku 설치+실행 중인가
                    result.success(ShizukuInjector.isAvailable())
                }
                "shizuku_granted" -> {
                    // 이 앱에 Shizuku 권한이 허용되어 권한 주입을 쓸 수 있는가
                    result.success(ShizukuInjector.isReady())
                }
                "shizuku_request" -> {
                    // Shizuku 권한 요청(다이얼로그). 결과는 shizuku_granted 폴링으로 확인.
                    ShizukuInjector.requestPermission(0xA21)
                    result.success(true)
                }
                "check_video_permission" -> {
                    mainService?.let {
                        result.success(it.checkMediaPermission())
                    } ?: let {
                        result.success(false)
                    }
                }
                "check_service" -> {
                    Companion.flutterMethodChannel?.invokeMethod(
                        "on_state_changed",
                        mapOf("name" to "input", "value" to InputService.isOpen.toString())
                    )
                    Companion.flutterMethodChannel?.invokeMethod(
                        "on_state_changed",
                        mapOf("name" to "media", "value" to MainService.isReady.toString())
                    )
                    result.success(true)
                }
                "stop_input" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        InputService.ctx?.disableSelf()
                    }
                    InputService.ctx = null
                    Companion.flutterMethodChannel?.invokeMethod(
                        "on_state_changed",
                        mapOf("name" to "input", "value" to InputService.isOpen.toString())
                    )
                    result.success(true)
                }
                "cancel_notification" -> {
                    if (call.arguments is Int) {
                        val id = call.arguments as Int
                        mainService?.cancelNotification(id)
                    } else {
                        result.success(true)
                    }
                }
                "enable_soft_keyboard" -> {
                    // https://blog.csdn.net/hanye2020/article/details/105553780
                    if (call.arguments as Boolean) {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM)
                    } else {
                        window.addFlags(WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM)
                    }
                    result.success(true)

                }
                "try_sync_clipboard" -> {
                    rdClipboardManager?.syncClipboard(true)
                    result.success(true)
                }
                GET_START_ON_BOOT_OPT -> {
                    val prefs = getSharedPreferences(KEY_SHARED_PREFERENCES, MODE_PRIVATE)
                    result.success(prefs.getBoolean(KEY_START_ON_BOOT_OPT, false))
                }
                SET_START_ON_BOOT_OPT -> {
                    if (call.arguments is Boolean) {
                        val prefs = getSharedPreferences(KEY_SHARED_PREFERENCES, MODE_PRIVATE)
                        val edit = prefs.edit()
                        edit.putBoolean(KEY_START_ON_BOOT_OPT, call.arguments as Boolean)
                        edit.apply()
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                SYNC_APP_DIR_CONFIG_PATH -> {
                    if (call.arguments is String) {
                        val prefs = getSharedPreferences(KEY_SHARED_PREFERENCES, MODE_PRIVATE)
                        val edit = prefs.edit()
                        edit.putString(KEY_APP_DIR_CONFIG_PATH, call.arguments as String)
                        edit.apply()
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                GET_VALUE -> {
                    if (call.arguments is String) {
                        if (call.arguments == KEY_IS_SUPPORT_VOICE_CALL) {
                            result.success(isSupportVoiceCall())
                        } else {
                            result.error("-1", "No such key", null)
                        }
                    } else {
                        result.success(null)
                    }
                }
                "on_voice_call_started" -> {
                    onVoiceCallStarted()
                }
                "on_voice_call_closed" -> {
                    onVoiceCallClosed()
                }
                else -> {
                    result.error("-1", "No such method", null)
                }
            }
        }
    }

    private fun setCodecInfo() {
        val codecList = MediaCodecList(MediaCodecList.REGULAR_CODECS)
        val codecs = codecList.codecInfos
        val codecArray = JSONArray()

        val windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val wh = getScreenSize(windowManager)
        var w = wh.first
        var h = wh.second
        val align = 64
        w = (w + align - 1) / align * align
        h = (h + align - 1) / align * align
        codecs.forEach { codec ->
            val codecObject = JSONObject()
            codecObject.put("name", codec.name)
            codecObject.put("is_encoder", codec.isEncoder)
            var hw: Boolean? = null;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                hw = codec.isHardwareAccelerated
            } else {
                // https://chromium.googlesource.com/external/webrtc/+/HEAD/sdk/android/src/java/org/webrtc/MediaCodecUtils.java#29
                // https://chromium.googlesource.com/external/webrtc/+/master/sdk/android/api/org/webrtc/HardwareVideoEncoderFactory.java#229
                if (listOf("OMX.google.", "OMX.SEC.", "c2.android").any { codec.name.startsWith(it, true) }) {
                    hw = false
                } else if (listOf("c2.qti", "OMX.qcom.video", "OMX.Exynos", "OMX.hisi", "OMX.MTK", "OMX.Intel", "OMX.Nvidia").any { codec.name.startsWith(it, true) }) {
                    hw = true
                }
            }
            if (hw != true) {
                return@forEach
            }
            codecObject.put("hw", hw)
            var mime_type = ""
            codec.supportedTypes.forEach { type ->
                if (listOf("video/avc", "video/hevc").contains(type)) { // "video/x-vnd.on2.vp8", "video/x-vnd.on2.vp9", "video/av01"
                    mime_type = type;
                }
            }
            if (mime_type.isNotEmpty()) {
                codecObject.put("mime_type", mime_type)
                val caps = codec.getCapabilitiesForType(mime_type)
                if (codec.isEncoder) {
                    // Encoder's max_height and max_width are interchangeable
                    if (!caps.videoCapabilities.isSizeSupported(w,h) && !caps.videoCapabilities.isSizeSupported(h,w)) {
                        return@forEach
                    }
                }
                codecObject.put("min_width", caps.videoCapabilities.supportedWidths.lower)
                codecObject.put("max_width", caps.videoCapabilities.supportedWidths.upper)
                codecObject.put("min_height", caps.videoCapabilities.supportedHeights.lower)
                codecObject.put("max_height", caps.videoCapabilities.supportedHeights.upper)
                val surface = caps.colorFormats.contains(COLOR_FormatSurface);
                codecObject.put("surface", surface)
                val nv12 = caps.colorFormats.contains(COLOR_FormatYUV420SemiPlanar)
                codecObject.put("nv12", nv12)
                if (!(nv12 || surface)) {
                    return@forEach
                }
                codecObject.put("min_bitrate", caps.videoCapabilities.bitrateRange.lower / 1000)
                codecObject.put("max_bitrate", caps.videoCapabilities.bitrateRange.upper / 1000)
                if (!codec.isEncoder) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        codecObject.put("low_latency", caps.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency))
                    }
                }
                if (!codec.isEncoder) {
                    return@forEach
                }
                codecArray.put(codecObject)
            }
        }
        val result = JSONObject()
        result.put("version", Build.VERSION.SDK_INT)
        result.put("w", w)
        result.put("h", h)
        result.put("codecs", codecArray)
        FFI.setCodecInfo(result.toString())
    }

    private fun onVoiceCallStarted() {
        var ok = false
        mainService?.let {
            ok = it.onVoiceCallStarted()
        } ?: let {
            isAudioStart = true
            ok = audioRecordHandle.onVoiceCallStarted(null)
        }
        if (!ok) {
            // Rarely happens, So we just add log and msgbox here.
            Log.e(logTag, "onVoiceCallStarted fail")
            flutterMethodChannel?.invokeMethod("msgbox", mapOf(
                "type" to "custom-nook-nocancel-hasclose-error",
                "title" to "Voice call",
                "text" to "Failed to start voice call."))
        } else {
            Log.d(logTag, "onVoiceCallStarted success")
        }
    }

    private fun onVoiceCallClosed() {
        var ok = false
        mainService?.let {
            ok = it.onVoiceCallClosed()
        } ?: let {
            isAudioStart = false
            ok = audioRecordHandle.onVoiceCallClosed(null)
        }
        if (!ok) {
            // Rarely happens, So we just add log and msgbox here.
            Log.e(logTag, "onVoiceCallClosed fail")
            flutterMethodChannel?.invokeMethod("msgbox", mapOf(
                "type" to "custom-nook-nocancel-hasclose-error",
                "title" to "Voice call",
                "text" to "Failed to stop voice call."))
        } else {
            Log.d(logTag, "onVoiceCallClosed success")
        }
    }

    override fun onStop() {
        super.onStop()
        val disableFloatingWindow = FFI.getLocalOption("disable-floating-window") == "Y"
        if (!disableFloatingWindow && MainService.isReady) {
            startService(Intent(this, FloatingWindowService::class.java))
        }
    }

    override fun onStart() {
        super.onStart()
        stopService(Intent(this, FloatingWindowService::class.java))
    }
}

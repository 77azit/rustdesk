package com.carriez.flutter_hbb

import android.app.admin.DeviceAdminReceiver

// 키오스크관리: device-owner 수신기.
// ADB 프로비저닝:
//   adb shell dpm set-device-owner com.azit.kioskmanager/com.carriez.flutter_hbb.AzitAdminReceiver
class AzitAdminReceiver : DeviceAdminReceiver()

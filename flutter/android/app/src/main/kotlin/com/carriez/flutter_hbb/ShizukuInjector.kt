package com.carriez.flutter_hbb

import android.content.pm.PackageManager
import android.util.Log
import rikka.shizuku.Shizuku
import java.util.concurrent.Executors

/**
 * 접근성 제스처 주입이 막힌 기기(KTC 등 상업용 디스플레이)에서
 * Shizuku(shell 권한)를 통해 `input` 명령으로 터치를 주입한다.
 *
 * 활성 조건: 기기에 Shizuku가 설치+실행 중이고, 이 앱에 Shizuku 권한이 허용됨.
 * 그렇지 않으면 isReady()=false → 기존 접근성 경로(dispatchGesture)로 폴백.
 */
object ShizukuInjector {
    private const val TAG = "ShizukuInjector"

    // input 명령을 순서대로(메인 스레드 차단 없이) 실행
    private val exec = Executors.newSingleThreadExecutor()

    /** Shizuku 서비스가 살아있나 */
    fun isAvailable(): Boolean = try {
        Shizuku.pingBinder()
    } catch (e: Throwable) {
        false
    }

    /** 이 앱에 Shizuku 권한이 허용됐나 */
    fun hasPermission(): Boolean = try {
        Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
    } catch (e: Throwable) {
        false
    }

    /** 권한 주입을 실제로 쓸 수 있는 상태 */
    fun isReady(): Boolean = isAvailable() && hasPermission()

    /** 권한 요청(결과는 Shizuku 권한 다이얼로그로) */
    fun requestPermission(code: Int) {
        try {
            Shizuku.requestPermission(code)
        } catch (e: Throwable) {
            Log.e(TAG, "requestPermission err $e")
        }
    }

    // Shizuku.newProcess 는 @RestrictTo(LIBRARY_GROUP) → 리플렉션으로 호출.
    private fun newProcess(cmd: Array<String>): Process? = try {
        val m = Shizuku::class.java.getDeclaredMethod(
            "newProcess",
            Array<String>::class.java,
            Array<String>::class.java,
            String::class.java
        )
        m.isAccessible = true
        m.invoke(null, cmd, null, null) as? Process
    } catch (e: Throwable) {
        Log.e(TAG, "newProcess err $e")
        null
    }

    /** 화면 좌표 탭 주입 (권한 있는 input 명령) */
    fun tap(x: Int, y: Int) {
        exec.execute {
            try {
                newProcess(arrayOf("input", "tap", x.toString(), y.toString()))?.waitFor()
            } catch (e: Throwable) {
                Log.e(TAG, "tap err $e")
            }
        }
    }

    /** 스와이프/드래그 주입 */
    fun swipe(x1: Int, y1: Int, x2: Int, y2: Int, durMs: Long) {
        exec.execute {
            try {
                newProcess(
                    arrayOf(
                        "input", "swipe",
                        x1.toString(), y1.toString(),
                        x2.toString(), y2.toString(),
                        durMs.toString()
                    )
                )?.waitFor()
            } catch (e: Throwable) {
                Log.e(TAG, "swipe err $e")
            }
        }
    }
}

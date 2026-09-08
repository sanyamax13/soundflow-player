package ru.soundflow.soundflow

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// AudioServiceFragmentActivity вместо FlutterActivity — нужно audio_service
// для медиа-сессии (Bluetooth-магнитола, наушники, экран блокировки), см.
// lib/features/player/audio_handler.dart, 05.09.2026.
//
// MethodChannel "soundflow/device" — модель телефона и тип связи (Wi-Fi /
// провод / моб. интернет) для окна «Устройства» на компьютере (Alex TG
// 18917). Своя пара строк на Kotlin, без сторонних пакетов.
class MainActivity : AudioServiceFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "soundflow/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "info" -> result.success(
                        mapOf("model" to deviceModel(), "transport" to transport())
                    )
                    else -> result.notImplemented()
                }
            }
    }

    private fun deviceModel(): String {
        val maker = Build.MANUFACTURER?.trim().orEmpty()
        val model = Build.MODEL?.trim().orEmpty()
        val name = when {
            model.isEmpty() -> maker
            maker.isEmpty() -> model
            model.startsWith(maker, ignoreCase = true) -> model
            else -> "$maker $model"
        }
        if (name.isEmpty()) return "Android"
        return name.replaceFirstChar { if (it.isLowerCase()) it.titlecase() else it.toString() }
    }

    private fun transport(): String {
        if (Build.VERSION.SDK_INT < 23) return ""
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return ""
        val net = cm.activeNetwork ?: return ""
        val caps = cm.getNetworkCapabilities(net) ?: return ""
        return when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "mobile"
            else -> ""
        }
    }
}

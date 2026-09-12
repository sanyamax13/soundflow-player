package ru.soundflow.soundflow

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// AudioServiceFragmentActivity вместо FlutterActivity — нужно audio_service
// для медиа-сессии (Bluetooth-магнитола, наушники, экран блокировки), см.
// lib/features/player/audio_handler.dart, 05.09.2026.
//
// MethodChannel "soundflow/device" — модель телефона и тип связи (Wi-Fi /
// провод / моб. интернет) для окна «Устройства» на компьютере (Alex TG
// 18917); плюс installApk — запуск системного установщика для
// автообновления (12.09.2026). Своя пара строк на Kotlin, без сторонних
// пакетов.
class MainActivity : AudioServiceFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "soundflow/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "info" -> result.success(
                        mapOf("model" to deviceModel(), "transport" to transport())
                    )
                    "appVersionCode" -> result.success(installedVersionCode())
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("no_path", "path is required", null)
                            return@setMethodCallHandler
                        }
                        val uri = FileProvider.getUriForFile(
                            this, "ru.soundflow.soundflow.fileprovider", File(path)
                        )
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivity(intent)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // Свой versionCode приложения — вместо package_info_plus (у него на
    // этой машине падает Kotlin-инкрементальный кэш Gradle, т.к. pub-cache
    // на диске C:, а проект на E: — Windows не строит relative path между
    // разными дисками, известный баг тулчейна, не нашего кода). Нужен для
    // автообновления (12.09.2026) — сравнить со version.json на VDS.
    private fun installedVersionCode(): Int {
        val info = packageManager.getPackageInfo(packageName, 0)
        return if (Build.VERSION.SDK_INT >= 28) info.longVersionCode.toInt() else {
            @Suppress("DEPRECATION")
            info.versionCode
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

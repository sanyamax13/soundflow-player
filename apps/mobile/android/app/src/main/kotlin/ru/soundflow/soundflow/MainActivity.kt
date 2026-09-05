package ru.soundflow.soundflow

import com.ryanheise.audioservice.AudioServiceFragmentActivity

// AudioServiceFragmentActivity вместо FlutterActivity — нужно audio_service
// для медиа-сессии (Bluetooth-магнитола, наушники, экран блокировки), см.
// lib/features/player/audio_handler.dart, 05.09.2026.
class MainActivity : AudioServiceFragmentActivity()

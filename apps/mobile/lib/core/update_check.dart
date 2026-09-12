import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

const _deviceChannel = MethodChannel('soundflow/device');

/// Канал обновлений SoundFlow — статика на VDS Alex-а (vdsmusic.ru),
/// работает из любой сети, не завязан на домашний сервер (12.09.2026,
/// см. docs/superpowers/specs/2026-09-12-app-update-channel-design.md).
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.versionCode,
    required this.apkUrl,
    required this.changelog,
  });

  final String version;
  final int versionCode;
  final String apkUrl;
  final String changelog;
}

const _versionUrl = 'https://vdsmusic.ru/soundflow/version';

/// null = обновлений нет (в т.ч. если сервер недоступен — не пугаем,
/// просто как будто не нашли ничего новее, как ведёт себя AutoSync).
Future<UpdateInfo?> checkForUpdate({Dio? client, int? installedVersionCode}) async {
  final dio = client ?? Dio();
  try {
    final myVersionCode = installedVersionCode ??
        await _deviceChannel.invokeMethod<int>('appVersionCode') ?? 0;
    final res = await dio.get<Map<String, dynamic>>(_versionUrl);
    final data = res.data;
    if (data == null) return null;
    final code = (data['versionCode'] as num).toInt();
    if (code <= myVersionCode) return null;
    return UpdateInfo(
      version: '${data['version']}',
      versionCode: code,
      apkUrl: '${data['apkUrl']}',
      changelog: '${data['changelog'] ?? ''}',
    );
  } catch (_) {
    return null;
  }
}

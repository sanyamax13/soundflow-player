import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const _channel = MethodChannel('soundflow/device');

/// Качает APK по [apkUrl] в кэш приложения и просит систему поставить
/// (один тап пользователя — Android иначе не даёт, см. спек).
Future<void> downloadAndInstallUpdate(String apkUrl, {Dio? client}) async {
  final dio = client ?? Dio();
  final cacheDir = await getTemporaryDirectory();
  final updatesDir = Directory('${cacheDir.path}/updates');
  if (!updatesDir.existsSync()) updatesDir.createSync(recursive: true);
  final fileName = apkUrl.split('/').last;
  final path = '${updatesDir.path}/$fileName';
  await dio.download(apkUrl, path);
  await _channel.invokeMethod<void>('installApk', {'path': path});
}

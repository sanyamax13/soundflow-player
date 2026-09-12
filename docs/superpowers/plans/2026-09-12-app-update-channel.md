# Автообновление SoundFlow — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** SoundFlow на телефоне само проверяет версию на VDS Alex-а
(vdsmusic.ru) из любой сети и предлагает поставить новую (один тап), без
Google Play/Obtainium/VPN.

**Architecture:** Статика на VDS (version.json + apk/) отдаётся nginx рядом
с уже рабочим `/taskme/*`. В приложении — `update_check.dart` (сравнить
версии через `dio`) и `update_download.dart` (скачать APK через `dio`) +
один нативный Kotlin-канал `soundflow/device` в `MainActivity.kt`
(тот же, что уже был для модели телефона) — теперь ещё и
`appVersionCode` (прочитать свою версию) и `installApk` (запустить
системный установщик через `FileProvider`). Без единой новой сторонней
библиотеки — обе рассмотренные (`package_info_plus`, `open_filex`)
оказались проблемными на практике (см. спек, раздел «Клиент»).

**Tech Stack:** Flutter/Dart (apps/mobile), Kotlin (MainActivity.kt), nginx
(VDS vdsmusic.ru), dio 5.11.1 (уже в проекте, новых зависимостей нет).

**Spec:** `docs/superpowers/specs/2026-09-12-app-update-channel-design.md`

## Global Constraints

- Подпись APK не меняется (тот же debug keystore) — иначе Android не
  поставит обновление поверх старой версии.
- Ни один существующий nginx location-блок на VDS не редактируется —
  только добавление новых.
- Сетевые ошибки при проверке версии проглатываются молча (нет
  интернета/сервер недоступен ≠ ошибка, просто «обновлений нет»), как
  ведёт себя существующий AutoSync.
- `dart analyze` чист после каждой задачи (проект держит 0 ошибок).
- Домен для канала обновлений: `https://vdsmusic.ru/soundflow/`.

---

### Task 1: Клиент проверки версии (без новых зависимостей)

**Files:**
- Create: `apps/mobile/lib/core/update_check.dart`
- Test: `apps/mobile/test/update_check_test.dart`

Версия приложения читается через уже существующий (расширенный в Task 2)
нативный канал `soundflow/device`, метод `appVersionCode` — не через
пакет (см. Global Constraints / спек).

**Interfaces:**
- Produces: `class UpdateInfo { final String version; final int versionCode; final String apkUrl; final String changelog; }`
  и `bool isNewerThan(int installedVersionCode)` на нём;
  `Future<UpdateInfo?> checkForUpdate({Dio? client, int? installedVersionCode})`
  — на входе можно подменить `client` и `installedVersionCode` для теста
  (реальный вызов без параметров сам берёт версию через
  `MethodChannel('soundflow/device').invokeMethod('appVersionCode')`
  и новый `Dio()`).

- [ ] **Step 1: Написать падающий тест сравнения версий**

Файл `apps/mobile/test/update_check_test.dart`:

```dart
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/core/update_check.dart';

void main() {
  test('находит более новую версию', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeAdapter('''
        {"version":"1.0.0","versionCode":40,
         "apkUrl":"https://vdsmusic.ru/soundflow/apk/SoundFlow-1.0.0+40.apk",
         "changelog":"тест","releasedAt":"2026-09-12T00:00:00+03:00"}
      ''');
    final info = await checkForUpdate(client: dio, installedVersionCode: 35);
    expect(info, isNotNull);
    expect(info!.versionCode, 40);
    expect(info.apkUrl, contains('SoundFlow-1.0.0+40.apk'));
  });

  test('своя версия не старше — обновления нет', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeAdapter('''
        {"version":"1.0.0","versionCode":35,
         "apkUrl":"https://vdsmusic.ru/soundflow/apk/SoundFlow-1.0.0+35.apk",
         "changelog":"","releasedAt":"2026-09-12T00:00:00+03:00"}
      ''');
    final info = await checkForUpdate(client: dio, installedVersionCode: 35);
    expect(info, isNull);
  });

  test('сервер недоступен — молча null, не бросает', () async {
    final dio = Dio()..httpClientAdapter = _ThrowingAdapter();
    final info = await checkForUpdate(client: dio, installedVersionCode: 35);
    expect(info, isNull);
  });
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.body);
  final String body;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture) async {
    return ResponseBody.fromString(body, 200,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  }
}

class _ThrowingAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture) async {
    throw DioException(requestOptions: options, error: 'no network');
  }
}
```

Добавить нужные импорты `dart:typed_data` для `Uint8List` в начало файла.

- [ ] **Step 2: Прогнать тест, убедиться что падает**

```
cd apps/mobile && flutter test test/update_check_test.dart
```
Ожидается: FAIL — `update_check.dart` не существует (`Error: Not found: 'package:soundflow/core/update_check.dart'`).

- [ ] **Step 3: Написать `update_check.dart`**

```dart
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
  final myVersionCode = installedVersionCode ??
      await _deviceChannel.invokeMethod<int>('appVersionCode') ?? 0;
  try {
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
```

- [ ] **Step 4: Прогнать тест, убедиться что проходит**

```
cd apps/mobile && flutter test test/update_check_test.dart
```
Ожидается: 3 теста PASS.

- [ ] **Step 5: `dart analyze` и коммит**

```
cd apps/mobile && dart analyze lib/ test/
git add apps/mobile/pubspec.yaml apps/mobile/pubspec.lock apps/mobile/lib/core/update_check.dart apps/mobile/test/update_check_test.dart
git commit -m "feat(mobile): проверка версии SoundFlow на VDS-канале обновлений"
```

---

### Task 2: Скачивание APK + нативная установка (Kotlin, как soundflow/device)

**Files:**
- Create: `apps/mobile/lib/core/update_download.dart`
- Modify: `apps/mobile/android/app/src/main/AndroidManifest.xml`
- Create: `apps/mobile/android/app/src/main/res/xml/file_paths.xml`
- Modify: `apps/mobile/android/app/src/main/kotlin/ru/soundflow/soundflow/MainActivity.kt`

**Interfaces:**
- Consumes: ничего из Task 1 напрямую (принимает `apkUrl` строкой — можно
  передать `UpdateInfo.apkUrl` из вызывающего кода).
- Produces: `Future<void> downloadAndInstallUpdate(String apkUrl, {Dio? client})`
  — качает, потом сам просит систему поставить (кидает исключение наружу,
  если скачивание не удалось — вызывающий код в Task 3 ловит и показывает
  «не получилось скачать»).

- [ ] **Step 1: AndroidManifest.xml — permission + provider**

В `apps/mobile/android/app/src/main/AndroidManifest.xml` добавить после
существующего блока `<uses-permission>` (после `WAKE_LOCK`/
`FOREGROUND_SERVICE*`, перед `<application`):

```xml
    <!-- Автообновление (12.09.2026): один тап ставит скачанную APK.
         Android всё равно спросит подтверждение — тихой установки без
         тапа платформа не даёт никому, кроме системных приложений. -->
    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>
```

Внутри `<application ...>` (после `android:networkSecurityConfig=...>`,
перед `<activity`) добавить провайдер:

```xml
        <provider
            android:name="androidx.core.content.FileProvider"
            android:authorities="ru.soundflow.soundflow.fileprovider"
            android:exported="false"
            android:grantUriPermissions="true">
            <meta-data
                android:name="android.support.FILE_PROVIDER_PATHS"
                android:resource="@xml/file_paths" />
        </provider>
```

- [ ] **Step 2: `res/xml/file_paths.xml`**

Создать `apps/mobile/android/app/src/main/res/xml/file_paths.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<paths xmlns:android="http://schemas.android.com/apk/res/android">
    <cache-path name="updates" path="updates/" />
</paths>
```

(APK будет качаться в `<кэш приложения>/updates/`, см. Step 4 — только
эта подпапка и открывается наружу через провайдер, не весь кэш.)

- [ ] **Step 3: MainActivity.kt — метод `installApk`**

Добавить в существующий `MainActivity.kt` новый импорт и обработку
метода `installApk` в уже существующем `MethodChannel` (канал
`soundflow/device` — переиспользуем тот же, добавляем новый `case`, не
плодим второй канал):

```kotlin
import android.content.Intent
import androidx.core.content.FileProvider
import java.io.File
```

В `when (call.method) { ... }` внутри уже существующего
`setMethodCallHandler`, рядом с `"info" -> ...`, добавить ДВА новых
случая — `appVersionCode` (версия приложения, без `package_info_plus` —
см. Global Constraints) и `installApk`:

```kotlin
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
```

(Обёртка `return@setMethodCallHandler` — потому что это лямбда, а не
обычная функция; без метки `return` внутри `if` не скомпилируется.)

И новый приватный метод рядом с `deviceModel()`/`transport()`:

```kotlin
    private fun installedVersionCode(): Int {
        val info = packageManager.getPackageInfo(packageName, 0)
        return if (Build.VERSION.SDK_INT >= 28) info.longVersionCode.toInt() else {
            @Suppress("DEPRECATION")
            info.versionCode
        }
    }
```

- [ ] **Step 4: `update_download.dart`**

```dart
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
```

- [ ] **Step 5: Собрать и проверить, что манифест/провайдер не сломали сборку**

```
cd apps/mobile
export PATH="/e/flutter/bin:$PATH"
dart analyze lib/
flutter build apk --debug --target-platform android-arm64
```
Ожидается: analyze чист, `flutter build apk` завершается без ошибок
манифеста/ресурсов (сборку ставить на телефон НЕ надо — по правилу
«APK собирать только по прямой просьбе Alex», это только проверка что
манифест/XML валидны).

- [ ] **Step 6: Коммит**

```
git add apps/mobile/android/app/src/main/AndroidManifest.xml \
        apps/mobile/android/app/src/main/res/xml/file_paths.xml \
        apps/mobile/android/app/src/main/kotlin/ru/soundflow/soundflow/MainActivity.kt \
        apps/mobile/lib/core/update_download.dart
git commit -m "feat(mobile): скачать и поставить обновление — нативный installApk (Kotlin)"
```

---

### Task 3: Экран — тихая проверка при запуске + кнопка в Профиле

**Files:**
- Modify: `apps/mobile/lib/features/profile/profile_screen.dart`
- Test: `apps/mobile/test/profile_update_test.dart`

**Interfaces:**
- Consumes: `checkForUpdate()` из Task 1, `downloadAndInstallUpdate()` из Task 2.
- Produces: ничего наружу — конечный узел UI.

- [ ] **Step 1: Написать тест на появление строки «Доступно обновление»**

```dart
// apps/mobile/test/profile_update_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/features/profile/profile_screen.dart';

void main() {
  testWidgets('строка "О программе" видна всегда', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ProfileScreen()));
    await tester.pumpAndSettle();
    expect(find.text('О программе'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Прогнать, убедиться что падает** (строки «О программе» ещё нет)

```
cd apps/mobile && flutter test test/profile_update_test.dart
```

- [ ] **Step 3: Добавить секцию в `profile_screen.dart`**

Добавить импорты в начало файла:
```dart
import 'package:flutter/services.dart';

import '../../core/update_check.dart';
import '../../core/update_download.dart';
```

Заменить последнюю строку списка (`const _Row(icon: Icons.settings_outlined, ...)`)
и всё до неё оставить как есть, добавив новый элемент СРАЗУ ПОСЛЕ него,
перед закрывающей `],`:

```dart
          const _Row(icon: Icons.settings_outlined, title: 'Настройки', subtitle: 'скоро'),
          const _UpdateRow(),
```

Добавить новый виджет в конец файла (после класса `_Row`):

```dart
/// «О программе» — версия + автопроверка обновления при открытии Профиля
/// (тихо, без всплывающих окон) + кнопка «Проверить сейчас» (Alex,
/// 12.09.2026 — канал vdsmusic.ru, см. update_check.dart).
class _UpdateRow extends StatefulWidget {
  const _UpdateRow();

  @override
  State<_UpdateRow> createState() => _UpdateRowState();
}

class _UpdateRowState extends State<_UpdateRow> {
  String _installed = '…';
  UpdateInfo? _available;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    const channel = MethodChannel('soundflow/device');
    final code = await channel.invokeMethod<int>('appVersionCode') ?? 0;
    if (!mounted) return;
    setState(() => _installed = 'v$code');
    final update = await checkForUpdate();
    if (mounted) setState(() => _available = update);
  }

  Future<void> _install() async {
    final u = _available;
    if (u == null || _busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await downloadAndInstallUpdate(u.apkUrl);
    } catch (_) {
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Не получилось скачать обновление')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = _available;
    if (u == null) {
      return _Row(
        icon: Icons.info_outline,
        title: 'О программе',
        subtitle: 'установлена $_installed',
        onTap: _busy ? null : _load,
      );
    }
    return _Row(
      icon: Icons.system_update_outlined,
      title: _busy ? 'Скачивание…' : 'Доступно обновление v${u.version}',
      subtitle: u.changelog.isEmpty ? 'нажми, чтобы поставить' : u.changelog,
      onTap: _busy ? null : _install,
    );
  }
}
```

- [ ] **Step 4: Прогнать тест, убедиться что проходит**

```
cd apps/mobile && flutter test test/profile_update_test.dart
```

- [ ] **Step 5: `dart analyze`, ручная проверка на реальном телефоне (см. Global Constraints — не заявлять «готово» без этого), коммит**

```
cd apps/mobile && dart analyze lib/ test/
git add apps/mobile/lib/features/profile/profile_screen.dart apps/mobile/test/profile_update_test.dart
git commit -m "feat(mobile): секция «О программе» — проверка и установка обновления"
```

Ручная проверка (обязательно перед тем как считать фичу готовой):
поставить текущую сборку на телефон Alex, открыть «Профиль» → должно
показать «установлена vNN» без обновлений (version.json на VDS ещё не
создан на этом шаге — Task 4). После Task 4 с намеренно завышенным
`versionCode` — должна появиться строка «Доступно обновление», тап →
скачивает → показывает системный экран установки.

---

### Task 4: VDS — новые location-блоки nginx + первая публикация

**Files:**
- Modify (на VDS, не в git-репозитории): `/etc/nginx/sites-enabled/vdsmusic.ru`
- Create (на VDS): `/var/www/soundflow/version.json`, `/var/www/soundflow/apk/`

Это инфраструктурная задача (не Dart-код) — тест здесь: `curl` возвращает
ожидаемое. Действовать только через SSH `root@77.239.102.216` (ключ
`~/.ssh/id_ed25519`, уже проверен рабочим в этой сессии).

- [ ] **Step 1: Бэкап конфига**

```
ssh -i ~/.ssh/id_ed25519 root@77.239.102.216 \
  "cp /etc/nginx/sites-enabled/vdsmusic.ru /etc/nginx/sites-enabled/vdsmusic.ru.bak-soundflow-update-20260912"
```

- [ ] **Step 2: Создать директории на VDS**

```
ssh -i ~/.ssh/id_ed25519 root@77.239.102.216 \
  "mkdir -p /var/www/soundflow/apk"
```

- [ ] **Step 3: Добавить 2 новых location-блока**

Вставить в `/etc/nginx/sites-enabled/vdsmusic.ru` СРАЗУ ПОСЛЕ существующего
блока `location /taskme/kadr/ { ... }` и ПЕРЕД `# /taskme/pwa/ — static PWA demo`
(рядом с однотипными блоками, ничего существующего не менять):

```nginx
    # /soundflow/* — канал автообновления SoundFlow (12.09.2026), по
    # образцу /taskme/version и /taskme/apk/ выше. Не завязан на домашний
    # сервер/tunnel_api — чистая статика, работает из любой сети.
    location = /soundflow/version {
        alias /var/www/soundflow/version.json;
        default_type application/json;
        add_header Cache-Control "no-store" always;
    }
    location /soundflow/apk/ {
        alias /var/www/soundflow/apk/;
        types { application/vnd.android.package-archive apk; }
        add_header Content-Disposition "attachment" always;
    }
```

Правка через `ssh ... "sed -n ..."`/эвристику рискованна на боевом
конфиге — сделать так: скачать файл на brain (`scp` конфиг во временную
папку scratchpad), вставить блок локально Edit-инструментом, залить
обратно `scp`, и только потом `nginx -t`.

- [ ] **Step 4: Проверить синтаксис ПЕРЕД перезапуском**

```
ssh -i ~/.ssh/id_ed25519 root@77.239.102.216 "nginx -t"
```
Ожидается: `syntax is ok` / `test is successful`. Если НЕТ — откатить из
бэкапа (Step 1) и разбираться, `systemctl reload` НЕ звать.

- [ ] **Step 5: Перезапустить только после успешного -t**

```
ssh -i ~/.ssh/id_ed25519 root@77.239.102.216 "systemctl reload nginx"
```

- [ ] **Step 6: Первая публикация — версия для проверки**

Положить `version.json` (versionCode на 1 больше текущего установленного
у Alex, чтобы Task 3's ручная проверка увидела «есть обновление») и
реальный APK файл под тем же именем, что в `apkUrl`:

```
scp <актуальный apk> root@77.239.102.216:/var/www/soundflow/apk/SoundFlow-1.0.0+NN.apk
# version.json готовится локально (Write), потом:
scp version.json root@77.239.102.216:/var/www/soundflow/version.json
```

- [ ] **Step 7: Проверка**

```
curl -sI https://vdsmusic.ru/soundflow/version
curl -s https://vdsmusic.ru/soundflow/version
curl -sI https://vdsmusic.ru/soundflow/apk/SoundFlow-1.0.0+NN.apk
```
Ожидается: первые два — 200 и корректный JSON; третий — 200 и
`Content-Type: application/vnd.android.package-archive`.

- [ ] **Step 8: Записать привычку в PROGRESS.md**

Добавить в `docs/PROGRESS.md` (продолжение записи по этапу 66/автообновлению):
после каждой новой APK для Alex — те же 3 команды (scp apk, обновить
version.json, scp, curl-проверка). Закоммитить обновление PROGRESS.md
(git-часть, VDS-файлы не в git).

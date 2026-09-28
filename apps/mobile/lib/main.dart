import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart' show CupertinoScrollBehavior;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/providers.dart';
import 'app/shell.dart';
import 'features/onboarding/connect_screen.dart';
import 'features/player/seek_skin.dart';
import 'core/black_box.dart';
import 'core/config.dart';
import 'core/crash_log.dart';
import 'core/device_info.dart';
import 'core/notice.dart';
import 'core/server_discovery.dart';
import 'core/theme.dart';
import 'data/api.dart';
import 'data/auto_sync.dart';
import 'data/db.dart';
import 'data/downloads_repo.dart';
import 'data/sync_offer.dart';
import 'data/sync_repo.dart';
import 'features/player/audio_handler.dart';
import 'features/player/player_controller.dart';

Future<void> main() async {
  // «Чёрный ящик»: ловим ВСЕ необработанные ошибки (Flutter, платформенный
  // слой, асинхронные из плагинов) и пишем последнюю в файл — иначе вылет
  // приложения не оставлял никакого следа (Alex TG 19028). Запуск целиком —
  // внутри одной зоны, иначе часть ошибок мимо.
  runZonedGuarded(_boot, (error, stack) {
    if (_isNetworkError(error)) {
      _logNetworkError(error, 'zone');
      return;
    }
    CrashLog.write(error, stack, where: 'zone');
  });
}

/// Пропала связь (нет интернета, не нашёлся адрес vdsmusic.ru, сервер не ответил) — это не падение
/// приложения: музыка играет дальше. Раньше такая непойманная ошибка показывалась в Профиле как
/// «Приложение падало» (Alex, скрин 27.09.2026: «Failed host lookup: 'vdsmusic.ru'»). Пишем в
/// «чёрный ящик» как «нет сети», чтобы найти, откуда она пришла.
bool _isNetworkError(Object e) =>
    e is SocketException ||
    e is HttpException ||
    e is HandshakeException ||
    (e is DioException &&
        (e.type == DioExceptionType.connectionError ||
            e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.receiveTimeout ||
            e.type == DioExceptionType.sendTimeout));

void _logNetworkError(Object e, String where) =>
    BlackBox.log('net_error', {'where': where, 'error': e.toString().split('\n').first});

Future<void> _boot() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    // Обложка не подгрузилась по сети (не дома, нет связи) — это не падение
    // приложения; раньше такое попадало в «Последний сбой» (Alex TG 20169).
    if (isHarmlessImageError(details)) {
      BlackBox.log('image_error', {'error': details.exceptionAsString()});
      return;
    }
    CrashLog.write(details.exception, details.stack, where: 'flutter');
  };
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    if (_isNetworkError(error)) {
      _logNetworkError(error, 'platform');
      return true;
    }
    CrashLog.write(error, stack, where: 'platform');
    return true;
  };

  final db = await Db.open();
  await loadSeekSkin(db); // вид полосы в плеере (features/player/seek_skin.dart)
  final dbg = await db.kvGet('debug_live') == '1';
  // Адрес сервера пользователь задаёт в Профиле — берём сохранённый. Совсем
  // новая установка (ничего не сохранено) — пробуем один раз сами найти
  // программу в сети/по USB, прежде чем откатиться на адрес по умолчанию
  // (см. core/config.dart; Alex TG 13.09.2026 — не заставлять вводить руками
  // при первом запуске).
  final savedUrl = await db.kvGet('server_url');
  // Совсем новый телефон и компьютер не нашёлся по USB — сначала экран «Найти компьютер»
  // (features/onboarding/connect_screen.dart).
  var firstRun = false;
  if (savedUrl != null && savedUrl.isNotEmpty) {
    apiBase = savedUrl;
  } else {
    // scanSubnet: false — только 127.0.0.1 (USB), не тянуть старт на
    // секунды ради полного перебора подсети; для этого есть кнопка в
    // Профиле.
    final found = await discoverServer(scanSubnet: false)
        .timeout(const Duration(seconds: 3), onTimeout: () => null);
    if (found != null) {
      apiBase = found;
      await db.kvSet('server_url', found);
    } else {
      firstRun = true;
    }
  }
  final api = Api(baseUrl: apiBase);
  // Удалённый доступ через VDS («Настройки → Удалённый доступ», Alex TG
  // 24.09.2026) — если в прошлый раз был включён вручную, поднимаем его
  // снова при каждом запуске (переключатель не «на сегодня», а до тех пор,
  // пока сами не выключат).
  if (await db.kvGet('relay_enabled') == '1') {
    final relayUrl = await db.kvGet('relay_url');
    final relayKey = await db.kvGet('relay_key');
    if (relayUrl != null && relayUrl.isNotEmpty && relayKey != null && relayKey.isNotEmpty) {
      api.setRelayTransport(relayUrl, relayKey);
      // Дома — напрямую, не через VDS (сам выбирает дорогу; см. Api.pickRoute).
      final home = await db.kvGet('server_url');
      if (home != null && home.isNotEmpty) api.setHomeUrl(home);
      api.onHomeUrlLearned = (url) => unawaited(db.kvSet('server_url', url));
      // Не ждём: вне дома проверка «дом отвечает?» тянулась до 4 с на заставке (ревизия кода
      // 27.09.2026). Пока не выбрали — идём через VDS, как раньше; дальше AutoSync перепроверяет.
      unawaited(api.pickRoute().catchError((Object _) => false));
    }
  }
  final sync = SyncRepo(api, db);
  // Подробный «чёрный ящик» (Alex TG 21786): всё пишется в файл дня и само уходит на
  // домашний сервер (core/black_box.dart).
  BlackBox.start(upload: (gz) async => api.uploadBlackBox(await sync.deviceId(), gz));
  if (dbg) BlackBox.setLive(true);
  final downloads = DownloadsRepo(api, db, sync);
  // late — onMissingFile ссылается на player, чтобы вернуть трек в очередь
  // после докачки (см. PlayerController.requeueTrack); замыкание просто
  // держит ссылку, вызовется уже после присвоения ниже.
  late final PlayerController player;
  player = PlayerController(
    onPlay: (m) {
      unawaited(sync.record('play', trackId: m.id));
      unawaited(db.markPlayed(m.id)); // для «забытого» в Потоке
    },
    onSkip: (m, pos, total) => sync.record('skip', trackId: m.id, payload: {
      'position_ms': pos.inMilliseconds,
      'duration_ms': total.inMilliseconds,
    }),
    onComplete: (m) => sync.record('complete', trackId: m.id),
    onDuration: (id, total) => downloads.noteFileMeta(id, total),
    // Выравнивание громкости (26.09.2026): громкость песни с сервера лежит в базе телефона.
    loudnessOf: db.loudnessOf,
    // Где остановились — для продолжения после закрытия приложения системой (stream_screen.dart).
    onResumePoint: (t, pos) => unawaited(db.kvSet(
        'resume_point',
        jsonEncode({
          'id': t.id,
          'title': t.title,
          'artist': t.artist,
          'path': t.path,
          'cover': t.coverPath,
          'pos_ms': pos.inMilliseconds,
        }))),
    // Файл трека пропал, плеер его пропустил (не падает, но и не играет) —
    // Alex TG 15.09.2026 «давай чинить, а не пропускать»: докачиваем заново
    // и возвращаем в очередь. Не вышло (сеть моргнула / трек правда стёрли
    // на сервере) — молча оставляем пропущенным, как раньше.
    onMissingFile: (m) async {
      try {
        await downloads.redownloadMissingFile(m.id);
        await player.requeueTrack(m);
      } catch (_) {}
    },
  );
  // Медиа-сессия Android — чтобы кнопки на Bluetooth-магнитоле в машине,
  // наушниках, руле и экране блокировки управляли плеером (05.09.2026,
  // просьба Alex — без этого магнитола ничего не переключала).
  await AudioService.init(
    builder: () => SoundFlowAudioHandler(player),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'ru.soundflow.soundflow.audio',
      androidNotificationChannelName: 'SoundFlow — плеер',
      androidNotificationOngoing: true,
    ),
  );
  // Три фоновые докачки — уже скачанным трекам:
  //  - обложки без файла (05.09.2026);
  //  - характеристики: битрейт/формат/длина, один запрос каталога (Alex TG 18704);
  //  - отпечатки для офлайн-радио (13.09.2026).
  // Оптимизация 21.09.2026 (Alex TG 20331): раньше все три стартовали сразу и
  // ВТРОЁМ одновременно, пока рисовался первый экран, а единственный поток базы
  // телефона нужен интерфейсу. Теперь — через несколько секунд после запуска и по
  // очереди; сбой одной не мешает остальным.
  Timer(const Duration(seconds: 8), () {
    unawaited(() async {
      final steps = <Future<void> Function()>[
        downloads.backfillCovers,
        downloads.backfillMeta,
        downloads.backfillVectors,
        downloads.backfillCoverRevs,
      ];
      for (final step in steps) {
        try {
          await step();
        } catch (error, stack) {
          CrashLog.write(error, stack, where: 'backfill');
        }
      }
    }());
  });
  // Сам отправляет накопленные лайки/удаления на сервер, как появится связь
  // (06.09.2026). Живёт всё время работы приложения.
  // Новые песни качаются сами дома по Wi-Fi (26.09.2026, разбор Gemini «плашки»);
  // переключатель — в «Связи с домом». Через удалённый доступ сами НЕ качаем.
  final offer = SyncOffer(
    downloads,
    autoDownload: await db.kvGet('auto_download') != '0',
    onAutoChanged: (v) => unawaited(db.kvSet('auto_download', v ? '1' : '0')),
    atHome: () async {
      if (api.relayHeaders.isNotEmpty) return false;
      final t = (await DeviceInfo.read()).transport;
      return t == 'wifi' || t == 'ethernet';
    },
  );
  AutoSync(sync, downloads, offer).start();
  // Было падение в прошлый раз — отправить его текст на компьютер (в ленту
  // «что делал сервер») и стереть: окна «Последний сбой» в Профиле больше нет (27.09.2026,
  // разбор Gemini и Алисы — сбои уходят домой сами). Нет связи — попробуем при следующем запуске.
  unawaited(() async {
    final crash = await CrashLog.read();
    if (crash == null) return;
    try {
      await api.reportCrash(await sync.deviceId(), crash);
      await CrashLog.clear();
    } catch (_) {}
  }());
  runApp(
    ProviderScope(
      overrides: [
        apiProvider.overrideWithValue(api),
        dbProvider.overrideWithValue(db),
        downloadsProvider.overrideWithValue(downloads),
        playerProvider.overrideWithValue(player),
        syncProvider.overrideWithValue(sync),
        syncOfferProvider.overrideWithValue(offer),
      ],
      child: SoundFlowApp(firstRun: firstRun),
    ),
  );
}

class SoundFlowApp extends StatelessWidget {
  const SoundFlowApp({super.key, this.firstRun = false});

  /// Новый телефон, компьютер ещё не знаком — начать с «Найти компьютер».
  final bool firstRun;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SoundFlow',
      debugShowCheckedModeBanner: false,
      theme: Afisha.theme(),
      // Прокрутка как на iPhone: списки чуть «пружинят» на краях (Alex TG 20345).
      scrollBehavior: const CupertinoScrollBehavior(),
      navigatorKey: rootNavigatorKey,
      navigatorObservers: [BlackBoxNavObserver()],
      // Плашка сообщений (core/notice.dart) — над всеми экранами и окнами.
      builder: (context, child) => NotificationListener<ScrollEndNotification>(
            onNotification: blackBoxScroll,
            child: NoticeHost(child: child ?? const SizedBox.shrink()),
          ),
      // Входа нет — сразу вкладки. Плеер личный, сервер в домашней сети.
      home: firstRun ? const ConnectScreen() : const Shell(),
    );
  }
}

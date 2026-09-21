import 'dart:async';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/providers.dart';
import 'app/shell.dart';
import 'core/config.dart';
import 'core/crash_log.dart';
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
    CrashLog.write(error, stack, where: 'zone');
  });
}

Future<void> _boot() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    // Обложка не подгрузилась по сети (не дома, нет связи) — это не падение
    // приложения; раньше такое попадало в «Последний сбой» (Alex TG 20169).
    if (isHarmlessImageError(details)) return;
    CrashLog.write(details.exception, details.stack, where: 'flutter');
  };
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    CrashLog.write(error, stack, where: 'platform');
    return true;
  };

  final db = await Db.open();
  // Адрес сервера пользователь задаёт в Профиле — берём сохранённый. Совсем
  // новая установка (ничего не сохранено) — пробуем один раз сами найти
  // программу в сети/по USB, прежде чем откатиться на адрес по умолчанию
  // (см. core/config.dart; Alex TG 13.09.2026 — не заставлять вводить руками
  // при первом запуске).
  final savedUrl = await db.kvGet('server_url');
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
    }
  }
  final api = Api(baseUrl: apiBase);
  final sync = SyncRepo(api, db);
  final downloads = DownloadsRepo(api, db, sync);
  // late — onMissingFile ссылается на player, чтобы вернуть трек в очередь
  // после докачки (см. PlayerController.requeueTrack); замыкание просто
  // держит ссылку, вызовется уже после присвоения ниже.
  late final PlayerController player;
  player = PlayerController(
    onPlay: (m) => sync.record('play', trackId: m.id),
    onSkip: (m, pos, total) => sync.record('skip', trackId: m.id, payload: {
      'position_ms': pos.inMilliseconds,
      'duration_ms': total.inMilliseconds,
    }),
    onComplete: (m) => sync.record('complete', trackId: m.id),
    onDuration: (id, total) => downloads.noteFileMeta(id, total),
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
  final offer = SyncOffer(downloads);
  AutoSync(sync, downloads, offer).start();
  // Было падение в прошлый раз — отправить его текст на компьютер (в ленту
  // «что делал сервер»). Файл не стираем: он ещё покажется в Профиле, Alex
  // уберёт кнопкой. Нет связи — попробуем при следующем запуске.
  unawaited(() async {
    final crash = await CrashLog.read();
    if (crash == null) return;
    try {
      await api.reportCrash(await sync.deviceId(), crash);
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
      child: const SoundFlowApp(),
    ),
  );
}

class SoundFlowApp extends StatelessWidget {
  const SoundFlowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SoundFlow',
      debugShowCheckedModeBanner: false,
      theme: Afisha.theme(),
      navigatorKey: rootNavigatorKey,
      // Плашка сообщений (core/notice.dart) — над всеми экранами и окнами.
      builder: (context, child) =>
          NoticeHost(child: child ?? const SizedBox.shrink()),
      // Входа нет — сразу вкладки. Плеер личный, сервер в домашней сети.
      home: const Shell(),
    );
  }
}

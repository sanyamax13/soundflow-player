import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api.dart';
import '../data/db.dart';
import '../data/downloads_repo.dart';
import '../data/sync_offer.dart';
import '../data/sync_repo.dart';
import '../features/player/player_controller.dart';

/// Общие сервисы приложения (замена `AppScope`, §5 плана). Реальные экземпляры
/// собираются в `main()` — там нужна уже открытая база (это async), поэтому
/// провайдер не может построить их сам. И в `main()`, и в тестах экземпляры
/// кладутся в `ProviderScope(overrides: [...])` через `overrideWithValue`.
/// Тело-заглушка ниже не должно вызываться никогда — если сработало, значит
/// забыли override.
Never _missing(String name) =>
    throw StateError('$name не переопределён в ProviderScope');

final apiProvider =
    Provider<Api>((ref) => _missing('apiProvider'));

final downloadsProvider =
    Provider<DownloadsRepo>((ref) => _missing('downloadsProvider'));

final playerProvider =
    Provider<PlayerController>((ref) => _missing('playerProvider'));

final syncProvider =
    Provider<SyncRepo>((ref) => _missing('syncProvider'));

final dbProvider =
    Provider<Db>((ref) => _missing('dbProvider'));

final syncOfferProvider =
    Provider<SyncOffer>((ref) => _missing('syncOfferProvider'));

import 'dart:convert';
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../core/black_box.dart';
import '../core/config.dart';

/// Заказ трека не удался — текст уже человеческий, можно показывать как есть.
class AcquireException implements Exception {
  AcquireException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Компьютер прямо сейчас уже собирает «Волну» (см. [Api.wave]) — не ошибка,
/// просто нужно подождать и попробовать снова.
class WaveBuildingException implements Exception {
  @override
  String toString() => 'волна уже пересобирается — подождите минуту';
}

/// Слепок вкуса, пришедший с сервера — центры long_term+recent как «сырые»
/// векторы (little-endian float32, 8192 байта на каждый при VecDim=2048).
class TasteCentroids {
  const TasteCentroids({required this.hash, required this.longTerm, required this.recent});
  final String hash;
  final List<Uint8List> longTerm;
  final List<Uint8List> recent;
}

/// Клиент к серверу на Go. Входа нет — плеер личный, сервер в домашней сети.
class Api {
  Api({String? baseUrl})
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl ?? apiBase,
          connectTimeout: const Duration(seconds: 8),
        )) {
    apiBase = _dio.options.baseUrl; // держим глобальный адрес в согласии с клиентом
    // «Чёрный ящик»: каждый запрос к серверу — куда, что ответил, сколько ждали.
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (o, h) {
        o.extra['bb_t0'] = DateTime.now().millisecondsSinceEpoch;
        h.next(o);
      },
      onResponse: (r, h) {
        _bbHttp(r.requestOptions, r.statusCode, r.headers.value('content-length'), null);
        h.next(r);
      },
      onError: (e, h) {
        _bbHttp(e.requestOptions, e.response?.statusCode, null, e.type.name);
        h.next(e);
      },
    ));
  }

  static void _bbHttp(RequestOptions o, int? status, String? bytes, String? error) {
    if (o.path.startsWith('/v1/blackbox')) return;
    final t0 = o.extra['bb_t0'] as int?;
    BlackBox.log('http', {
      'method': o.method,
      'path': o.path,
      if (o.queryParameters.isNotEmpty) 'query': o.queryParameters.toString(),
      'status': status,
      if (t0 != null) 'ms': DateTime.now().millisecondsSinceEpoch - t0,
      'bytes': ?bytes,
      'error': ?error,
      'via': o.headers.containsKey(_kRelayKeyHeader) ? 'vds' : 'home',
    });
  }

  /// Кусок «чёрного ящика» (строки JSON, сжатые gzip) — на домашний сервер.
  Future<void> uploadBlackBox(String deviceId, List<int> gz) async {
    await _dio.post<Object>(
      '/v1/blackbox',
      queryParameters: {'device': deviceId},
      data: Stream.fromIterable([gz]),
      options: Options(
        headers: {
          'Content-Encoding': 'gzip',
          'Content-Type': 'application/x-ndjson',
          Headers.contentLengthHeader: gz.length,
        },
        sendTimeout: const Duration(seconds: 60),
        receiveTimeout: const Duration(seconds: 60),
      ),
    );
  }

  final Dio _dio;

  /// Только для тестов — подменить HTTP-адаптер фейковым.
  set debugAdapter(HttpClientAdapter a) => _dio.httpClientAdapter = a;

  /// Текущий адрес сервера, к которому обращается клиент.
  String get baseUrl => _dio.options.baseUrl;

  /// Сменить адрес сервера на лету (Профиль → «Адрес сервера»). Ввод
  /// приводится к `http://хост:порт`. Сохранение в базу — на вызывающем.
  void setBaseUrl(String raw) {
    final v = normalizeServerUrl(raw);
    _dio.options.baseUrl = v;
    apiBase = v;
  }

  static const _kRelayKeyHeader = 'X-Soundflow-Relay-Key';

  /// Включить удалённый доступ через VDS («Настройки → Удалённый доступ»,
  /// Alex TG 24.09.2026): адрес с путём (`.../soundflow-remote`), поэтому
  /// НЕ через [setBaseUrl]/normalizeServerUrl — та ждёт вид «хост:порт» и
  /// обрежет путь. Секретный ключ уходит на каждый запрос отдельным
  /// заголовком, как ждёт relayAuth на сервере.
  void setRelayTransport(String relayUrl, String relayKey) {
    _relayUrl = relayUrl;
    _relayKey = relayKey;
    _useRelay();
  }

  /// Вернуться с удалённого доступа на обычный (домашний Wi-Fi/USB) адрес.
  void disableRelay(String localUrl) {
    _relayUrl = null;
    _relayKey = null;
    _dio.options.headers.remove(_kRelayKeyHeader);
    setBaseUrl(localUrl);
  }

  // Удалённый доступ включён, но дома через VDS ходить незачем: «чёрный ящик» 26.09.2026 показал,
  // что с включённым удалённым доступом телефон и дома ходил через интернет — 0,8–4 с на запрос, и
  // автоскачивание не срабатывало. Теперь дорога выбирается сама: дом отвечает напрямую — напрямую,
  // иначе через VDS ([pickRoute] — при запуске и в каждом заходе AutoSync).
  String? _relayUrl;
  String? _relayKey;
  String? _homeUrl;

  /// Домашний адрес сервера (сохранённый «Адрес дома») — для выбора дороги.
  void setHomeUrl(String url) => _homeUrl = normalizeServerUrl(url);

  /// Сервер сообщил новый домашний адрес и он ответил — сохранить (main.dart пишет в базу).
  void Function(String url)? onHomeUrlLearned;

  void _useRelay() {
    final url = _relayUrl, key = _relayKey;
    if (url == null || key == null) return;
    _dio.options.baseUrl = url;
    _dio.options.headers[_kRelayKeyHeader] = key;
    apiBase = url;
  }

  /// Выбрать дорогу к серверу. Удалённый доступ выключен — ничего не делает. Возвращает true, если
  /// сейчас идём напрямую (дома).
  Future<bool> pickRoute() async {
    if (_relayUrl == null) return true;
    final wasRelay = relayHeaders.isNotEmpty;
    var home = _homeUrl;
    var atHome = home != null && await ping(home, timeout: const Duration(milliseconds: 1500));
    if (!atHome) {
      // Сохранённый адрес дома молчит — может, сервер переехал (26.09.2026: в телефоне остался адрес
      // brain). Спросить сервер через VDS, где он дома, и проверить этот адрес напрямую.
      try {
        _useRelay();
        final r = await _dio.get<Map<String, dynamic>>('/v1/health',
            options: Options(receiveTimeout: const Duration(seconds: 5)));
        final learned = r.data?['home'] as String?;
        if (learned != null && learned.isNotEmpty && learned != home &&
            await ping(learned, timeout: const Duration(milliseconds: 1500))) {
          home = _homeUrl = normalizeServerUrl(learned);
          atHome = true;
          onHomeUrlLearned?.call(home);
          BlackBox.log('route_home_learned', {'home': home});
        }
      } catch (_) {}
    }
    if (atHome && home != null) {
      _dio.options.headers.remove(_kRelayKeyHeader);
      _dio.options.baseUrl = home;
      apiBase = home;
    } else {
      _useRelay();
    }
    if (wasRelay == atHome) BlackBox.log('route', {'via': atHome ? 'home' : 'vds'});
    return atHome;
  }

  /// Заголовок с секретным ключом удалённого доступа (пусто — доступ не
  /// включён) — для запросов В ОБХОД Dio (плеер играет по прямой ссылке,
  /// см. [discoverPreviewUrl]), которые иначе не понесли бы этот заголовок
  /// сами и получили бы 403 от relayAuth на компьютере.
  Map<String, String> get relayHeaders {
    final v = _dio.options.headers[_kRelayKeyHeader];
    return v == null ? const {} : {_kRelayKeyHeader: '$v'};
  }

  /// Проверить сервер по адресу, НЕ переключаясь на него (кнопка «Проверить»
  /// в настройке адреса). true — ответил на /v1/health.
  static Future<bool> ping(String raw, {Duration timeout = const Duration(seconds: 5)}) async {
    try {
      final dio = Dio(BaseOptions(
        baseUrl: normalizeServerUrl(raw),
        connectTimeout: timeout,
        receiveTimeout: timeout,
      ));
      final r = await dio.get<Map<String, dynamic>>('/v1/health');
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Готов ли компьютер к первому подключению (Alex TG 24.09.2026): «Найти
  /// сервер самому» нашёл ответивший адрес, но подключаться молча больше
  /// нельзя — на компьютере должны нажать «Подключить телефон». `null` —
  /// сервер не ответил на эту ручку вообще (например, старая версия
  /// программы без этой функции) — тогда вызывающий сам решает, как быть
  /// (обычно — как раньше, без подтверждения).
  static Future<({bool open, String name})?> pairingCheck(String raw) async {
    try {
      final dio = Dio(BaseOptions(
        baseUrl: normalizeServerUrl(raw),
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
      ));
      final r = await dio.get<Map<String, dynamic>>('/api/pairing/check');
      final d = r.data;
      if (d == null) return null;
      return (open: d['open'] == true, name: (d['name'] as String?) ?? '');
    } catch (_) {
      return null;
    }
  }

  /// Подтвердить первое подключение — компьютер ещё должен быть в открытом
  /// окне («Подключить телефон»), иначе ok:false (окно истекло/закрыли).
  /// Заодно компьютер может сразу отдать адрес и ключ удалённого доступа
  /// через VDS (relay_url/relay_key), если он у него настроен (Alex TG
  /// 24.09.2026, вместо ручного ввода секрета) — их нет, если удалённый
  /// доступ на компьютере не включён; вызывающий сохраняет, что пришло.
  static Future<({bool ok, String? relayUrl, String? relayKey})> pairingConfirm(String raw) async {
    try {
      final dio = Dio(BaseOptions(
        baseUrl: normalizeServerUrl(raw),
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
      ));
      final r = await dio.post<Map<String, dynamic>>('/api/pairing/confirm');
      if (r.statusCode != 200) return (ok: false, relayUrl: null, relayKey: null);
      return (
        ok: true,
        relayUrl: r.data?['relay_url'] as String?,
        relayKey: r.data?['relay_key'] as String?,
      );
    } catch (_) {
      return (ok: false, relayUrl: null, relayKey: null);
    }
  }

  /// Список треков с сервера.
  Future<List<Map<String, dynamic>>> tracks({int? limit}) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/v1/tracks',
      queryParameters: limit == null ? null : {'limit': limit},
    );
    final list = (res.data?['tracks'] as List?) ?? const [];
    return list.cast<Map<String, dynamic>>();
  }

  /// Поиск по каталогу сервера (что уже скачано на домашний компьютер).
  /// Пустой запрос — вернёт последние добавленные.
  Future<List<Map<String, dynamic>>> searchCatalog(String q) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/v1/search',
      queryParameters: {'q': q},
    );
    final list = (res.data?['tracks'] as List?) ?? const [];
    return list.cast<Map<String, dynamic>>();
  }

  /// Заказать трек: сервер ищет и качает его на домашний компьютер
  /// (Яндекс.Музыка → musify → торренты) и кладёт в каталог. Долгая
  /// операция — до нескольких минут. Бросает [AcquireException] с понятным
  /// текстом, если не вышло.
  Future<Map<String, dynamic>> acquireTrack({
    required String artist,
    required String title,
    int durationSec = 0,
  }) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/v1/tracks/acquire',
        data: {'artist': artist, 'title': title, 'duration_sec': durationSec},
        options: Options(receiveTimeout: const Duration(minutes: 10)),
      );
      return res.data ?? const {};
    } on DioException catch (e) {
      final data = e.response?.data;
      final reason = (data is Map) ? '${data['reason'] ?? data['error'] ?? ''}' : '';
      throw AcquireException(_acquireMessage(e.response?.statusCode, reason));
    }
  }

  String _acquireMessage(int? code, String reason) {
    switch (code) {
      case 404:
        return 'Не нашлось ни в одном источнике';
      case 422:
        return reason.isNotEmpty ? reason : 'Нашлось только плохое качество';
      case 503:
        return 'Сервер сейчас не может качать (нет базы или связи с качалкой)';
      default:
        return reason.isNotEmpty ? reason : 'Сервер не ответил';
    }
  }

  /// Скачать файл трека в указанный путь.
  Future<void> downloadTrack(String id, String toPath) async {
    await _dio.download('/v1/music/$id/file', toPath);
  }

  /// Какие песни компьютер просит вернуть с телефона (разовый возврат стёртого
  /// с ПК, Alex TG 20261–20269, 21.09.2026): id, исполнитель, название, размер.
  /// Компьютер без этой ручки (старая версия программы) ответит 404 — бросит
  /// исключение, вызывающий код его глотает.
  Future<List<Map<String, dynamic>>> restoreWanted() async {
    final res = await _dio.get<List<dynamic>>('/api/restore/wanted');
    return (res.data ?? const []).cast<Map<String, dynamic>>();
  }

  /// Отдать компьютеру файл песни — он положит его на прежнее место. true —
  /// принят (или уже лежит там); false — компьютер файл не принял (не тот
  /// формат, обрезок, песни нет в списке): повторять бессмысленно. Нет связи
  /// или сбой на компьютере — бросит исключение, прогон остановится.
  Future<bool> restoreUpload(String id, File file) async {
    final len = await file.length();
    try {
      await _dio.put<dynamic>(
        '/api/restore/upload/$id',
        data: file.openRead(),
        options: Options(headers: {
          Headers.contentLengthHeader: len,
          Headers.contentTypeHeader: 'application/octet-stream',
        }),
      );
      return true;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code != null && code >= 400 && code < 500) return false;
      rethrow;
    }
  }

  /// Прислать компьютеру точный список песен на телефоне (id и размер файла) —
  /// для сверки телефона с компьютером в окне программы (Alex TG 20277–20279,
  /// 21.09.2026: «на телефоне столько песен, на компьютере столько»). Раньше
  /// компьютер знал состав только по журналу событий — приблизительно. Нет
  /// связи / старая программа на ПК — бросит исключение, вызывающий код
  /// его глотает.
  Future<void> sendInventory(String deviceId, List<({String id, int bytes})> items) async {
    await _dio.post<dynamic>('/api/phone/inventory', data: {
      'device_id': deviceId,
      'items': [
        for (final i in items) {'id': i.id, 'b': i.bytes},
      ],
    });
  }

  /// Сообщить компьютеру, каких из просимых песен на телефоне нет — ждать их
  /// файлы он перестаёт.
  Future<void> restoreMissing(List<String> ids) async {
    await _dio.post<dynamic>('/api/restore/missing', data: {'ids': ids});
  }

  /// Скачать обложку по прямой ссылке (Яндекс.Музыка) — чтобы играть офлайн
  /// вместе с песней, а не тянуть картинку по сети каждый раз.
  Future<void> downloadCover(String url, String toPath) => _dio.download(url, toPath);

  Future<Map<String, dynamic>> health() async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/health');
    return res.data ?? {};
  }

  /// Отправить текст последнего падения приложения на сервер (чёрный ящик,
  /// Alex TG 19028). Попадёт в ленту «что делал сервер». Не критично —
  /// вызывающий глотает ошибку.
  Future<void> reportCrash(String deviceId, String text) async {
    await _dio.post<Map<String, dynamic>>('/v1/client-crash', data: {
      'device': deviceId,
      'text': text,
    });
  }

  /// Рельеф громкости трека (0..1 по каждому столбику) для полоски плеера.
  /// Нет данных / ошибка — null (полоска рисуется как раньше).
  Future<List<double>?> waveform(String id) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>('/v1/waveform/$id');
      final bars = (res.data?['bars'] as List?)?.cast<num>();
      if (bars == null || bars.isEmpty) return null;
      return [for (final b in bars) (b.toDouble() / 255.0).clamp(0.0, 1.0)];
    } catch (_) {
      return null;
    }
  }

  /// Удары баса песни — 20 отметок 0..255 на секунду (сервер, basskeeper.go, 27.09.2026): по ним
  /// кнопка «играть» вспыхивает в такт. Нет (ещё не посчитано / нет связи) — null.
  Future<Uint8List?> bass(String id) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>('/v1/bass/$id');
      final env = res.data?['env'] as String?;
      if (env == null || env.isEmpty) return null;
      return base64Decode(env);
    } catch (_) {
      return null;
    }
  }

  /// Слепок вкуса — только версия (несколько байт), НЕ сами центры. Дёргаем
  /// после каждой синхронизации; если отличается от сохранённого локально —
  /// тянем полный [tasteCentroids]. Сервер недоступен → null (тихо, вкус
  /// не критичен для работы приложения).
  Future<String?> tasteCentroidsHash() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>('/api/taste/centroids-hash');
      return res.data?['hash'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Полный слепок вкуса (центры long_term+recent) — только когда хэш
  /// разошёлся с локальным (см. [tasteCentroidsHash]).
  Future<TasteCentroids?> tasteCentroids() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>('/api/taste/centroids');
      final data = res.data;
      if (data == null) return null;
      List<Uint8List> decode(String key) => [
            for (final s in (data[key] as List? ?? const []))
              base64Decode('$s'),
          ];
      return TasteCentroids(
        hash: '${data['hash'] ?? ''}',
        longTerm: decode('long_term'),
        recent: decode('recent'),
      );
    } catch (_) {
      return null;
    }
  }

  /// Список залайканных на телефоне песен, которых сервер не узнаёт (Alex
  /// TG 15.09.2026: старая библиотека стёрта, а лайки на телефоне остались,
  /// хочет их видеть на компе и докачать). Сервер сам решает, чего не
  /// хватает в каталоге — тут просто отправка сырого списка. Сеть недоступна
  /// → тихо, не критично.
  Future<void> reportPhoneFavorites(List<Map<String, String>> tracks) async {
    if (tracks.isEmpty) return;
    try {
      await _dio.post<void>('/api/phone/favorites', data: {'tracks': tracks});
    } catch (_) {}
  }

  /// Отпечатки треков — телефон дёргает сразу после скачивания и при
  /// разовом бэкфилле старых скачиваний. Отсутствующий id — тихо пропущен
  /// (не у каждого трека в каталоге есть отпечаток).
  Future<Map<String, Uint8List>> trackVectors(List<String> ids) async {
    if (ids.isEmpty) return {};
    try {
      final res = await _dio.post<Map<String, dynamic>>('/api/tracks/vectors', data: {'ids': ids});
      final vectors = (res.data?['vectors'] as Map?) ?? const {};
      return {
        for (final e in vectors.entries) '${e.key}': base64Decode('${e.value}'),
      };
    } catch (_) {
      return {};
    }
  }

  /// Отправить батч событий с телефона. Возвращает uuid принятых как новые
  /// (дубли сервер молча пропускает).
  Future<List<String>> postSyncEvents({
    required String deviceId,
    required List<Map<String, Object?>> events,
    int musicBytes = 0,
    String deviceName = 'Android',
    String transport = '',
  }) async {
    final res = await _dio.post<Map<String, dynamic>>('/v1/sync/events', data: {
      'device': {
        'id': deviceId,
        'name': deviceName,
        'app_version': 'dev',
        'music_bytes': musicBytes,
        'transport': transport,
      },
      'events': events,
    });
    final acc = (res.data?['accepted'] as List?) ?? const [];
    return acc.map((e) => '$e').toList();
  }

  /// Сообщить серверу, сколько песен из пачки «Докачать ещё» уже скачано —
  /// чтобы в окне «Устройства» на компьютере было видно «качает: <песня>,
  /// N из M» (Alex TG 18928). Не критично: сервер не ответил — молча дальше.
  Future<void> syncProgress({
    required String deviceId,
    required int done,
    required int total,
    required String current,
    required bool active,
  }) async {
    try {
      await _dio.post<Map<String, dynamic>>('/v1/sync/progress', data: {
        'device_id': deviceId,
        'done': done,
        'total': total,
        'current': current,
        'active': active,
      });
    } catch (_) {
      // прогресс — необязательная мелочь, не мешаем скачиванию
    }
  }

  /// План ручной синхронизации, который Alex собрал в окне на компе (кнопка
  /// «Синхронизировать» → список с галочками → «Далее»). `add` — карточки
  /// треков к скачиванию, `remove` — id к удалению на телефоне. Плана нет
  /// (сервер ответил 204) — null.
  Future<
      ({
        List<Map<String, dynamic>> add,
        List<String> remove,
        String createdAt,
      })?> deviceSyncPlan(String deviceId) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/v1/device/plan',
      queryParameters: {'device': deviceId},
    );
    if (res.statusCode == 204 || res.data == null) return null;
    final add =
        ((res.data?['add'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final remove =
        ((res.data?['remove'] as List?) ?? const []).map((e) => '$e').toList();
    if (add.isEmpty && remove.isEmpty) return null;
    return (
      add: add,
      remove: remove,
      createdAt: '${res.data?['created_at'] ?? ''}',
    );
  }

  /// Отчитаться серверу, что план синхронизации выполнен — сервер его удалит.
  Future<void> ackSyncPlan(String deviceId) async {
    await _dio.post<Map<String, dynamic>>(
      '/v1/device/plan/ack',
      data: {'device': deviceId},
    );
  }

  /// Упорядочить очередь Потока по близости звучания к seed. Отдаём id всех
  /// скачанных треков, получаем их же в новом порядке (без seed).
  ///
  /// [reordered] = true только если подбор по звуку реально состоялся. Если у
  /// seed-песни нет «отпечатка» — вернётся тот же список в исходном порядке и
  /// `reordered: false`; телефон тогда не зажигает радио и пишет, что похожее
  /// не подобрать (06.09.2026).
  Future<({List<String> ids, bool reordered})> streamOrder({
    required String seedId,
    required List<String> candidateIds,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>('/v1/stream/order', data: {
      'seed_id': seedId,
      'candidate_ids': candidateIds,
    });
    final list = (res.data?['track_ids'] as List?) ?? const [];
    return (
      ids: list.map((e) => '$e').toList(),
      reordered: res.data?['reordered'] == true,
    );
  }

  /// Состояние сервера для экрана «Сервер».
  Future<Map<String, dynamic>> adminStatus() async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/admin/status');
    return res.data ?? {};
  }

  Future<List<Map<String, dynamic>>> adminDevices() async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/admin/devices');
    return ((res.data?['devices'] as List?) ?? const []).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> adminEvents({int limit = 20}) async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/admin/events',
        queryParameters: {'limit': limit});
    return ((res.data?['events'] as List?) ?? const []).cast<Map<String, dynamic>>();
  }

  /// Список «больше не качать» (удалённое в плеере + старый чёрный список).
  Future<List<Map<String, dynamic>>> blocklist({int limit = 500}) async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/admin/blocklist',
        queryParameters: {'limit': limit});
    return ((res.data?['blocked'] as List?) ?? const []).cast<Map<String, dynamic>>();
  }

  /// Убрать один ключ из списка «больше не качать» (случайно попал / передумал).
  Future<void> blocklistRemove(String key) async {
    await _dio.post<Map<String, dynamic>>('/v1/admin/blocklist/remove', data: {'key': key});
  }

  /// Лента «что делал сервер»: добавил трек, убрал, не нашёл, заменил на
  /// версию получше, ошибка. Новые сверху.
  Future<List<Map<String, dynamic>>> serverLog({int limit = 100}) async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/admin/log',
        queryParameters: {'limit': limit});
    return ((res.data?['log'] as List?) ?? const []).cast<Map<String, dynamic>>();
  }

  // ---- «Открытия» (Alex TG 24.09.2026): то же, что было только в окне на
  // компьютере (Яндекс-волна, плейлист по ссылке), теперь и на телефоне,
  // теми же ручками (см. discover_screen.dart). ----

  /// За какие дни есть подборка «Волны» — 0 (сегодня) и до 3 дней назад,
  /// только те, где что-то есть.
  Future<List<Map<String, dynamic>>> waveDays() async {
    final res = await _dio.get<List<dynamic>>('/api/yandex/wave/days');
    return (res.data ?? const []).cast<Map<String, dynamic>>();
  }

  /// Подборка «Волны» за день (0 — сегодня). [refresh] — «Пересобрать волну»
  /// (только для сегодня, игнорируется для прошлых дней сервером).
  ///
  /// Первый заход за сегодня (кэша ещё нет — до 6 утра, когда программа сама
  /// собирает подборку) реально ищет по Яндексу и торрентам — небыстро
  /// (поймано вживую 24.09.2026: телефон Alex сдался ждать раньше, чем
  /// компьютер закончил — «Компьютер недоступен» на пустом месте, хотя
  /// компьютер всё это время был жив и доделал сам). [WaveBuildingException] —
  /// компьютер уже собирает волну ПРЯМО СЕЙЧАС (другой заход) — не ошибка,
  /// подождать и попробовать снова.
  Future<List<Map<String, dynamic>>> wave({int day = 0, bool refresh = false}) async {
    try {
      final res = await _dio.get<List<dynamic>>(
        '/api/yandex/wave',
        queryParameters: {
          if (day > 0) 'day': day,
          if (refresh) 'refresh': '1',
        },
        options: Options(receiveTimeout: const Duration(minutes: 2)),
      );
      return (res.data ?? const []).cast<Map<String, dynamic>>();
    } on DioException catch (e) {
      if (e.response?.statusCode == 409) throw WaveBuildingException();
      rethrow;
    }
  }

  /// Песни по ссылке на плейлист Яндекс.Музыки — бросает с человеческим
  /// текстом, если ссылка не подошла (не та ссылка / плейлист закрыт).
  Future<({String title, List<Map<String, dynamic>> items})> yandexPlaylist(String url) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>('/api/yandex/playlist',
          queryParameters: {'url': url});
      final items = ((res.data?['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
      return (title: '${res.data?['title'] ?? ''}', items: items);
    } on DioException catch (e) {
      final msg = e.response?.data;
      throw AcquireException(msg is String && msg.isNotEmpty ? msg : 'Не получилось открыть плейлист');
    }
  }

  /// «Удалить» в «Открытиях» — скрыть песню из волны/плейлиста (не трогает
  /// лайки/каталог, можно вернуть — см. [discoverUndismiss]).
  Future<void> discoverDismiss(String artist, String title) async {
    await _dio.post<void>('/api/discover/dismiss', data: {'artist': artist, 'title': title});
  }

  /// «Вернуть» после «Удалить».
  Future<void> discoverUndismiss(String artist, String title) async {
    await _dio.post<void>('/api/discover/undismiss', data: {'artist': artist, 'title': title});
  }

  /// «Скачать» в «Открытиях» — запускает поиск и скачивание на компьютере
  /// (Яндекс → торренты, как и обычный заказ). Не ждёт результата — сервер
  /// качает в фоне; прогресс — см. [acquireLog].
  Future<void> discoverAcquire(String artist, String title) async {
    await _dio.post<void>('/api/acquire', queryParameters: {'artist': artist, 'title': title});
  }

  /// Последние попытки «Скачать» (свои и чужие — общий список на компьютере,
  /// последние 20) — artist/title/state (running|done|fail)/note. Alex TG
  /// 24.09.2026: «нет прогресс бара, качается ли, что делает» — опрашивается
  /// с экрана «Открытия», пока там что-то качается.
  Future<List<Map<String, dynamic>>> acquireLog() async {
    final res = await _dio.get<Map<String, dynamic>>('/api/acquire/log');
    return ((res.data?['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
  }

  /// Прямая ссылка на предпрослушку песни из «Открытий» (полная песня из
  /// Яндекса, отдаётся через компьютер) — используется как обычный audio-URL,
  /// без отдельного Dio-запроса.
  String discoverPreviewUrl({String? id, String? artist, String? title}) {
    final q = <String, String>{
      if (id != null && id.isNotEmpty) 'id': id,
      if (artist != null && artist.isNotEmpty) 'artist': artist,
      if (title != null && title.isNotEmpty) 'title': title,
    };
    final qs = q.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&');
    return '$baseUrl/api/yandex/preview?$qs';
  }

  /// Прямая ссылка на файл трека каталога компьютера — играть без скачивания
  /// на телефон (для очереди «разбор коллекции», трек может быть ещё не
  /// скачан на телефон).
  String catalogFileUrl(String id) => '$baseUrl/v1/music/$id/file';

  /// Удалить трек из каталога компьютера насовсем — та же функция, что
  /// «Удалить навсегда» в меню окна ПК: убирает с телефона (если скачан), из
  /// каталога компьютера, ставит метку blocked (не докачает снова), стирает
  /// файл с диска. Необратимо — вызывающий код должен подтвердить у Alex
  /// перед вызовом.
  Future<void> catalogDeleteForever(List<String> ids) async {
    await _dio.post<Map<String, dynamic>>('/api/tracks/delete-forever', data: {'ids': ids});
  }
}

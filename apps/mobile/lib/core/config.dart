/// Адрес компьютера с программой SoundFlow.
///
/// По умолчанию — `127.0.0.1:8090`: связь по USB-кабелю (Alex 08.09.2026,
/// «только USB»). Программа на компе сама поднимает adb-туннель, и запрос на
/// 127.0.0.1:8090 уходит в провод. Ничего вписывать не надо — поставил апк,
/// воткнул кабель, работает.
/// Wi-Fi (адрес вида 192.168.1.104) при желании задаётся в Профиле →
/// «Адрес сервера», выбор хранится в базе телефона (`server_url`).
/// Эмулятор: `--dart-define=SOUNDFLOW_API=http://10.0.2.2:8090`.
const String kDefaultApiBase = String.fromEnvironment(
  'SOUNDFLOW_API',
  defaultValue: 'http://127.0.0.1:8090',
);

/// Текущий адрес сервера. Меняется в Профиле (`Api.setBaseUrl`), читается при
/// старте из базы. Всё, что строит ссылки напрямую (обложки), смотрит сюда.
String apiBase = kDefaultApiBase;

/// Привести ввод пользователя к виду `http://хост:порт`.
/// «192.168.1.104» → «http://192.168.1.104:8090»; терпит ввод со схемой и
/// портом. Пусто → адрес по умолчанию.
String normalizeServerUrl(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return kDefaultApiBase;
  if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'http://$s';
  final u = Uri.tryParse(s);
  if (u == null || u.host.isEmpty) return kDefaultApiBase;
  final port = u.hasPort ? u.port : 8090;
  return '${u.scheme}://${u.host}:$port';
}

/// Обложка прямо из файла трека на сервере (`GET /v1/cover/{id}`) — сетевой
/// запасной вариант там, где нет локально скачанной картинки. Нет картинки
/// в файле — сервер ответит 404, экран откатится на серый плейсхолдер.
String coverUrlFor(String trackId) => '$apiBase/v1/cover/$trackId';

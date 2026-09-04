# Перенос со старого плеера

Каталог наполняется заново (решение Alex 05.08.2026), но личную разметку
сохраняем. Выгружено 04.09.2026 из старой базы (`soundflow-postgres` на fg,
только чтение).

## Файлы

- `legacy-favorites.json` — 10 избранных треков. Поля: artist, title, album,
  year, duration_sec, isrc, recording_mbid, language, genre_tags, liked_at.
- `legacy-blacklist.json` — 127 удалённых/скрытых. Поля: artist, title,
  normalized_key, kind (`permanent` / `temporary`), reason (`deleted` и т.п.),
  blacklisted_at, expires_at.

## Как подключим

Когда в новом приложении появится каталог песен (этап 3):
- по artist+title (нормализованно) находим совпадение в новом каталоге;
- из favorites → ставим ♥;
- из blacklist с kind=permanent / reason=deleted → помечаем удалённым
  (в Поток и списки не попадает). `temporary` игнорируем — это старые
  быстрые скипы на 14 дней, в новой модели их нет.

Совпадения не будет для треков, которых ещё нет в новом каталоге — отложим
их в «не найдено», подтянутся когда докачаются.

# Плейлист по ссылке вместо «Твоих лайков из Яндекс.Музыки» (20.09.2026)

Запрос Alex (TG 20117–20122, 20.09.2026): «пока не ставь [v13], давай сделаем, чтобы я САМ мог своё избранное из Яндекса
добавить, а не ты автоматически» + ссылка-образец `https://music.yandex.ru/playlists/lk.<uuid>?utm_medium=copy_link…`
(«вот так ссылка выглядит»). На мой вопрос «раздел „Твои лайки из Яндекс.Музыки“ (он подтягивался сам по токену) — оставить,
убрать совсем или другое?» Alex ответил «2» — **убрать совсем, только ссылки, само ничего не подтягивается**.

## Что сделано

- **Вкладка «Открытия»** (`frontend/index.html`): сверху поле «Вставь ссылку на плейлист Яндекс.Музыки (у плейлиста «Поделиться»)»
  и кнопка «Показать» (Enter тоже). Песни плейлиста — тем же списком, что «Волна»: слушать (полная, через качалку), галочки,
  «Выбрать все», «Скачать выбранные (N)», «Скачать», «Удалить» (= скрыть из списков «Открытий»), «✓ есть» у тех, что уже в каталоге.
  Раздел плейлиста раскрыт сразу, с названием «Плейлист «<название>»», кнопка «Закрыть» убирает его с экрана (в Яндексе ничего не меняется).
  **Один плейлист за раз** — новая ссылка заменяет прежний (выбор по умолчанию, TG 20045). Ссылки между запусками НЕ запоминаются.
  Понятные сообщения: пустое поле; «Не похоже на ссылку на плейлист Яндекс.Музыки…»; «Плейлист не открылся: ссылка устарела или плейлист закрыт…»;
  качалка не отвечает — как у остальных разделов.
- **Убрано:** раздел «Твои лайки из Яндекс.Музыки»; серверная ручка `GET /api/yandex/likes` и метод клиента `sidecar.Client.YandexLikes`;
  **молчаливый перенос «не нравится» из Яндекса в чёрный список при входе на вкладку** (страница больше не зовёт `POST /api/yandex/dislikes/import`
  — «само ничего не подтягивается»). Сама ручка `hYandexDislikesImport` и `/yandex/likes`/`/yandex/dislikes` в качалке остались без вызова.
- **Go** (`cmd/soundflow/yandex_playlist.go`): `GET /api/yandex/playlist?url=<ссылка>` → `{title, items:[…, already_have]}`; пометка `already_have`
  и скрытые кнопкой «Удалить» — как раньше у лайков; текст отказа качалки (`sidecar.PlaylistError`) доходит до Alex как есть (400),
  сбой связи с качалкой — 502; ссылка длиннее 2048 знаков — 400. Клиент: `internal/sidecar/client.go` `YandexPlaylist`.
- **Качалка** (живая копия вне git `E:\soundflow-lab\fg-sidecar-src`): `src/providers/yandex.py` (разбор ссылки, чтение плейлиста) и
  `src/main.py` (`GET /yandex/playlist?url=`). Бэкапы до правки: `yandex.py.bak-before-playlist-20260920`, `main.py.bak-before-playlist-20260920`
  (в корне папки качалки; откат — положить обратно). Тесты качалки — `tests/test_playlist_link.py` (стиль pytest, pytest в её `.venv` не стоит —
  прогнаны через заглушку, 14 проверок). **Новый код в качалке подхватывается только после её перезапуска** — то есть при замене программы.

## Как читается плейлист (проверено 20.09.2026, только чтение)

- `client.playlists_list("lk.<uuid>")` не работает («Parameters requirements are not met»). Работает
  `GET {base_url}/playlist/lk.<uuid>` (`client._request.get`): отдаёт название, все треки с полными данными (id, исполнители, название, альбом,
  обложка, длина). У плейлиста «Мне нравится» Alex — 576 в Яндексе, доступных в стране 573 (недоступные пропускаются).
- Работает и **без токена** для открытых (public) плейлистов (без токена 568 — часть доступна только по токену); токен, если он есть, используется.
- Вид `users/<логин>/playlists/<номер>` читается через `client.users_playlists` + пакетное `client.tracks([...])`.
- Саму ссылку качалка НЕ открывает — из неё берётся только идентификатор, домен обязан быть `music.yandex.(ru|com|by|kz|uz|ua)`; чужие
  домены, `javascript:`, `../` и т.п. отбрасываются (см. тест).

## Проверки

Go: `TestPlaylistHidesDismissedButKeepOnesInCatalog`, `TestPlaylistErrorsAreReadable`, `TestPlaylistSidecarDown` (+ остальные тесты пакета, `go vet` чисто).
Качалка: 14 проверок разбора ссылок; живое чтение настоящей ссылки Alex — 573 песни, обе формы ссылок, несуществующий плейлист — понятная ошибка.
Страница (Chromium, двойник с НАСТОЯЩИМИ песнями плейлиста, скрипт `pl_test.mjs`): поле сверху; ошибки понятным текстом; настоящая ссылка → 573 строки,
«есть» у 9; «Выбрать все» — 564 из 564; клик играет; «Удалить» убирает; другая ссылка заменяет; «Закрыть» убирает; «Волна» жива; `/api/yandex/likes` и
`/api/yandex/dislikes/import` не зовутся; ошибок JS нет. **Не проверено на устройстве:** настоящее окно Alex и настоящая цепочка окно → программа → перезапущенная качалка.

## Код качалки (копия, живой файл — вне git)

`src/providers/yandex.py` (вставлено перед `async def likes_tracks():`):

```python
# ───────── плейлист по ссылке (Alex TG 20117–20122, 20.09.2026) ─────────
# Alex сам вставляет ссылку на плейлист Яндекс.Музыки («Поделиться» у плейлиста, в том числе «Мне нравится»),
# а не берём его лайки сами по токену. Формы ссылок: https://music.yandex.ru/playlists/lk.<uuid> (и без «lk.»)
# и https://music.yandex.ru/users/<логин>/playlists/<номер>. Саму ссылку мы НЕ открываем — только вынимаем из неё
# идентификатор и спрашиваем API Яндекса; открытый (public) плейлист читается и без токена.
# Проверено 20.09.2026: client.playlists_list("lk.<uuid>") даёт «Parameters requirements are not met», а
# GET {base_url}/playlist/lk.<uuid> отдаёт название и все треки с полными данными.

_PL_HOST = re.compile(r"^(?:www\.)?music\.yandex\.(?:ru|com|by|kz|uz|ua)$", re.I)
_PL_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{5,79}$")
_PL_LOGIN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$")

PL_BAD_LINK = ("Не похоже на ссылку на плейлист Яндекс.Музыки. Открой плейлист в Яндекс.Музыке, "
               "нажми «Поделиться» и скопируй ссылку.")


def parse_playlist_link(link: str):
    """Ссылка → ("uuid", "<lk.xxx>") | ("user", "<логин>", "<номер>") | None."""
    from urllib.parse import urlparse
    try:
        u = urlparse((link or "").strip())
        host = u.hostname or ""
    except ValueError:
        return None
    if u.scheme not in ("http", "https") or not _PL_HOST.match(host):
        return None
    parts = [p for p in u.path.split("/") if p]
    if len(parts) == 2 and parts[0] == "playlists" and _PL_ID.match(parts[1]):
        return ("uuid", parts[1])
    if len(parts) == 4 and parts[0] == "users" and parts[2] == "playlists" and parts[3].isdigit() \
            and _PL_LOGIN.match(parts[1]):
        return ("user", parts[1], parts[3])
    return None


def _raw_track_item(t):
    """Трек из «сырого» ответа API (словарь) → тот же вид, что у лайков; недоступные в стране пропускаем."""
    if not t or t.get("available") is False:
        return None
    tid = t.get("id") or t.get("realId")
    if not tid:
        return None
    artist = ", ".join(a.get("name", "") for a in (t.get("artists") or []) if a and a.get("name"))
    albs = t.get("albums") or []
    cover = t.get("coverUri") or (albs[0].get("coverUri") if albs else None)
    dur = t.get("durationMs")
    return {
        "yandex_id": str(tid),
        "artist": artist,
        "title": t.get("title") or "",
        "album": (albs[0].get("title") if albs else "") or "",
        "cover_url": ("https://" + cover.replace("%%", "600x600")) if cover else None,
        "duration_sec": (dur // 1000) if dur else None,
    }


def _obj_track_item(t):
    """То же для объекта библиотеки yandex_music (как в _likes_sync)."""
    if t is None or getattr(t, "available", True) is False:
        return None
    return {
        "yandex_id": str(t.id),
        "artist": ", ".join(a.name for a in (t.artists or []) if a and a.name),
        "title": t.title or "",
        "album": (t.albums[0].title if t.albums else "") or "",
        "cover_url": _cover_url_of(t),
        "duration_sec": (t.duration_ms // 1000) if t.duration_ms else None,
    }


def _playlist_sync(link: str):
    """→ (название, [треки], ошибка). Ошибка — по-русски, готова для показа Alex."""
    ref = parse_playlist_link(link)
    if ref is None:
        return "", [], PL_BAD_LINK
    client = _get_client()
    if client is None:                       # токена нет — открытые плейлисты читаются и так
        try:
            from yandex_music import Client
            client = Client().init()
        except Exception as e:  # noqa: BLE001
            log.warning("yandex playlist: анонимный клиент не поднялся: %s", e)
            return "", [], "Яндекс сейчас не отвечает — попробуй чуть позже."
    try:
        if ref[0] == "uuid":
            raw = client._request.get(f"{client.base_url}/playlist/{ref[1]}")
            items = [it for it in (_raw_track_item(el.get("track")) for el in (raw.get("tracks") or [])) if it]
            return raw.get("title") or "Плейлист", items, None
        pls = client.users_playlists(int(ref[2]), user_id=ref[1])
        pl = pls[0] if isinstance(pls, list) else pls
        ids = [t.id for t in (pl.tracks or []) if getattr(t, "id", None)]
        full = client.tracks(ids) if ids else []
        items = [it for it in (_obj_track_item(t) for t in full) if it]
        return pl.title or "Плейлист", items, None
    except Exception as e:  # noqa: BLE001
        name = type(e).__name__
        log.warning("yandex playlist %s: %s %s", ref, name, e)
        if name in ("NotFoundError", "BadRequestError", "ForbiddenError"):
            return "", [], "Плейлист не открылся: ссылка устарела или плейлист закрыт (сделай его открытым и скопируй ссылку заново)."
        if name in ("NetworkError", "TimedOutError"):
            return "", [], "Яндекс не ответил — попробуй чуть позже."
        return "", [], "Не получилось открыть плейлист. Проверь ссылку."


async def playlist_by_link(link: str):
    """(название, [{yandex_id,artist,title,album,cover_url,duration_sec}], ошибка|None)."""
    return await asyncio.to_thread(_playlist_sync, link)
```

`src/main.py` (вставлено перед `class YandexStreamResponse`):

```python
class YandexPlaylistResponse(BaseModel):
    title: str = ""
    items: list[YandexLikeItem] = []
    error: str | None = None


@app.get("/yandex/playlist", response_model=YandexPlaylistResponse)
async def yandex_playlist(url: str = "") -> YandexPlaylistResponse:
    """Песни плейлиста Яндекс.Музыки по ссылке, которую Alex вставил сам (TG 20117–20122): вместо
    «лайки сами по токену». Ссылки: /playlists/lk.<uuid>, /users/<логин>/playlists/<номер>."""
    from .providers.yandex import playlist_by_link
    title, items, err = await playlist_by_link(url)
    return YandexPlaylistResponse(title=title, items=[YandexLikeItem(**i) for i in items], error=err)
```

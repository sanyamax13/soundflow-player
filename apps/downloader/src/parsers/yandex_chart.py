"""Yandex Music chart parser via MarshalX/yandex-music library.

Используется sidecar endpoint /yandex-chart. Возвращает русский топ
~100 треков с position, artist, title, cover_url, external_url.

Без OAuth-токена — публичная метадата (charts/albums/artists) доступна
анонимно. Token нужен только для скачивания аудио (нам не надо, у нас
своя 7-провайдер цепочка). См. yandex-music readthedocs.

Обновления чартов на Яндексе раз в день, дёргать чаще раза в час смысла нет.
"""
from __future__ import annotations
import logging
import re
from difflib import SequenceMatcher
from typing import Any

log = logging.getLogger(__name__)


def _norm_yx(s: str) -> str:
    return re.sub(r"[^a-zа-я0-9]+", "", (s or "").lower())


def _sim_yx(a: str, b: str) -> float:
    return SequenceMatcher(None, _norm_yx(a), _norm_yx(b)).ratio()


def yandex_track_duration(artist: str, title: str) -> int | None:
    """Официальная длительность трека (сек) из Яндекс.Музыки — эталон для
    отбраковки неправильных версий (ремикс/обрезка/чужая запись) при скачивании.

    Ищем по «artist title», берём первый результат, чей artist+title реально
    совпадает (фаззи), и возвращаем его duration_ms/1000. None если не нашли
    или Яндекс недоступен — тогда вызывающий просто не применяет фильтр длины.
    """
    try:
        from yandex_music import Client  # type: ignore[import-untyped]

        client = Client().init()
        res = client.search(f"{artist} {title}", type_="track")
        tracks = getattr(getattr(res, "tracks", None), "results", None) or []
        for t in tracks[:5]:
            dur_ms = getattr(t, "duration_ms", None) if t else None
            if not dur_ms:
                continue
            t_artist = ", ".join(a.name for a in (t.artists or []) if a and a.name)
            if _sim_yx(t.title or "", title) >= 0.7 and _sim_yx(t_artist, artist) >= 0.5:
                return int(dur_ms / 1000)
    except Exception as e:
        log.warning("yandex duration lookup failed for %r/%r: %s", artist, title, e)
    return None


def fetch_yandex_chart(chart_option: str = "russia") -> list[dict[str, Any]]:
    """Возвращает Яндекс чарт с position, artist, title, cover_url, external_url, genre.

    chart_option: 'russia' (русский) или 'world' (глобальный).

    Жанр track.genre НЕ заполнен в track_short — нужен дополнительный
    client.tracks([...]) batch-запрос для полных Track-объектов. Делаем
    один запрос на все 100 ids — это ~300ms против 100*30ms по одному.
    """
    from yandex_music import Client  # type: ignore[import-untyped]

    client = Client().init()
    chart_info = client.chart(chart_option)
    if not chart_info or not chart_info.chart or not chart_info.chart.tracks:
        log.warning("yandex chart %s returned empty", chart_option)
        return []

    # Сначала соберём базовые поля + соберём все track_id для batch-запроса.
    base_rows: list[dict[str, Any]] = []
    track_ids: list[str] = []
    for track_short in chart_info.chart.tracks:
        t = track_short.track
        if t is None or not t.id:
            continue
        chart_pos = track_short.chart
        position = chart_pos.position if chart_pos and chart_pos.position else None
        if position is None or position < 1:
            continue

        cover_url: str | None = None
        if t.cover_uri:
            cover_url = "https://" + t.cover_uri.replace("%%", "400x400")

        artist = ", ".join(a.name for a in (t.artists or []) if a and a.name) or "Unknown"
        title = (t.title or "").strip()
        if not title:
            continue

        external_url = f"https://music.yandex.ru/track/{t.id}"
        track_ids.append(str(t.id))
        base_rows.append({
            "position": position,
            "artist": artist,
            "title": title,
            "cover_url": cover_url,
            "external_url": external_url,
            "track_id": str(t.id),
            "genre": None,
            # Сигналы отсева подкастов/аудиокниг — обогащаем из batch ниже
            # (полные Track-объекты); duration_ms берём и тут как запас на случай
            # если batch упадёт (rate-limit/сеть).
            "duration_ms": getattr(t, "duration_ms", None),
            "track_type": (getattr(t, "type", None) or "").lower(),
            "album_meta": {
                (getattr(al, "meta_type", None) or "").lower()
                for al in (getattr(t, "albums", None) or [])
            },
        })

    # Batch-подгрузка полных Track-объектов чтобы достать genre.
    # client.tracks(ids) -> list[Track]. Если падает (rate-limit, network) —
    # отдаём что есть с genre=None (UI обработает).
    try:
        full_tracks = client.tracks(track_ids) if track_ids else []
        genre_by_id: dict[str, str] = {}
        meta_by_id: dict[str, dict[str, Any]] = {}
        for ft in full_tracks:
            if ft is None or not ft.id:
                continue
            g = (getattr(ft, "genre", None) or "").strip().lower()
            if g:
                genre_by_id[str(ft.id)] = g
            meta_by_id[str(ft.id)] = {
                "track_type": (getattr(ft, "type", None) or "").lower(),
                "album_meta": {
                    (getattr(al, "meta_type", None) or "").lower()
                    for al in (getattr(ft, "albums", None) or [])
                },
                "duration_ms": getattr(ft, "duration_ms", None),
            }
        for row in base_rows:
            row["genre"] = genre_by_id.get(row["track_id"])
            m = meta_by_id.get(row["track_id"])
            if m:
                if m["track_type"]:
                    row["track_type"] = m["track_type"]
                if m["album_meta"]:
                    row["album_meta"] = m["album_meta"]
                if m["duration_ms"]:
                    row["duration_ms"] = m["duration_ms"]
        log.info(
            "yandex-chart %s: resolved genres for %d/%d tracks",
            chart_option, sum(1 for r in base_rows if r["genre"]), len(base_rows),
        )
    except Exception as e:
        log.warning("yandex tracks() batch failed, genre fallback to None: %s", e)

    # Отсев подкастов/аудиокниг (по дебатам 07.06.2026): главный сигнал — метадата
    # Яндекса (тип трека / meta_type альбома) — точно и без ложных срабатываний,
    # ловит «Полка»/Омут. Длина — запасной грубый отсек (>20 мин: в поп-топе РФ
    # реальных песен такой длины нет, самая длинная 7.6 мин), гарантирует отсев
    # даже если метадата пустая. Ключевые слова НЕ используем (ложные срабатывания
    # на Mix/Глава/Эпизод в названиях песен). Логируем каждый отсев — без «тихих»
    # потерь, видно по логу sidecar. Этот фильтр ТОЛЬКО для Яндекс-чарта; длинные
    # ди-джей-миксы Radio Record (легит музыка) тут не затрагиваются.
    nonsong_types = {"podcast-episode", "podcast", "audiobook", "article", "show-episode"}
    nonsong_album = {"podcast", "audiobook", "article"}
    kept: list[dict[str, Any]] = []
    for row in base_rows:
        dur_ms = row.get("duration_ms")
        album_meta = row.get("album_meta") or set()
        reason: str | None = None
        if row.get("track_type") in nonsong_types:
            reason = f"type={row['track_type']}"
        elif album_meta & nonsong_album:
            reason = "album_meta=" + ",".join(sorted(album_meta & nonsong_album))
        elif dur_ms and dur_ms > 20 * 60 * 1000:
            reason = f"{round(dur_ms / 60000, 1)}min"
        if reason:
            log.info(
                "yandex-chart: skip non-song %r/%r (%s)", row["artist"], row["title"], reason,
            )
            continue
        kept.append(row)
    base_rows = kept

    items: list[dict[str, Any]] = []
    for row in base_rows:
        items.append({
            "position": row["position"],
            "artist": row["artist"],
            "title": row["title"],
            "cover_url": row["cover_url"],
            "external_url": row["external_url"],
            "genre": row["genre"],
        })

    # Дедуп по position (на случай странностей API)
    seen: set[int] = set()
    uniq: list[dict[str, Any]] = []
    for it in sorted(items, key=lambda x: x["position"]):
        if it["position"] not in seen:
            seen.add(it["position"])
            uniq.append(it)
    log.info("yandex-chart %s: parsed %d tracks", chart_option, len(uniq))
    return uniq

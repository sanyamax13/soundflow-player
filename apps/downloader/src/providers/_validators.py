"""Общий валидатор аудио-файлов для всех провайдеров.

Защищает от попадания «фейкового» аудио в track_files: HTML/JSON ответов
сервера с правильным content-type, обрезанных загрузок, мусора. Любой
провайдер должен вызвать validate_audio_file() сразу после того как файл
сохранён на диск, до того как INSERT в track_files.

Проверки:
1. Размер ≥ MIN_SIZE_BYTES (100 KB по умолчанию). mp3party ловили
   29-байтовые «failed to get file info: nil» с правильным content-type.
2. Magic bytes — первые 4 байта файла. Поддерживаем форматы которые
   реально качают наши провайдеры:
     - mp3 (ID3v2 или MPEG sync)
     - opus/ogg (OggS)
     - aac/m4a (ftyp на offset 4)
     - flac (fLaC)
     - webm (1A 45 DF A3)
   Этого достаточно — html, json, текстовые ошибки, обрезанные .part отсекаются.

Если файл невалидный — удаляем с диска и возвращаем False. Логируем с
указанием источника для диагностики.
"""
from __future__ import annotations

import logging
import re
from pathlib import Path

log = logging.getLogger(__name__)

DEFAULT_MIN_SIZE_BYTES = 100 * 1024  # 100 KB


def _has_audio_magic_bytes(head: bytes) -> bool:
    """True если первые байты соответствуют известному аудио-формату."""
    if len(head) < 4:
        return False
    # mp3: ID3v2 tag в начале
    if head[:3] == b"ID3":
        return True
    # mp3: MPEG audio sync header (frame без ID3 тега)
    if head[0] == 0xFF and (head[1] & 0xE0) == 0xE0:
        return True
    # opus/vorbis в Ogg-контейнере
    if head[:4] == b"OggS":
        return True
    # flac
    if head[:4] == b"fLaC":
        return True
    # m4a/aac/mp4 audio: ISO BMFF, ftyp на offset 4
    # head[4:8] == b"ftyp" — но мы читаем 8 байт, проверим
    if len(head) >= 8 and head[4:8] == b"ftyp":
        return True
    # webm (EBML)
    if head[:4] == b"\x1a\x45\xdf\xa3":
        return True
    # wav
    if head[:4] == b"RIFF":
        return True
    return False


def validate_audio_file(
    path: Path,
    *,
    source: str = "unknown",
    min_size_bytes: int = DEFAULT_MIN_SIZE_BYTES,
) -> bool:
    """Проверяет что файл действительно аудио. Если нет — удаляет и возвращает False.

    Параметры:
        path: путь к файлу
        source: имя провайдера для логов ('mp3party', 'soundcloud', 'rutracker', ...)
        min_size_bytes: минимальный размер (default 100 KB)

    Возвращает True если файл прошёл проверку и остался на диске.
    """
    if not path.exists():
        log.warning("[%s] validate: файл не существует: %s", source, path)
        return False

    try:
        size = path.stat().st_size
    except OSError as exc:
        log.warning("[%s] validate: stat failed для %s: %s", source, path, exc)
        return False

    if size < min_size_bytes:
        log.warning(
            "[%s] validate: %s слишком мал (%d bytes < %d), удаляю",
            source, path.name, size, min_size_bytes,
        )
        _safe_unlink(path)
        return False

    try:
        with path.open("rb") as f:
            head = f.read(8)
    except OSError as exc:
        log.warning("[%s] validate: не могу прочитать %s: %s", source, path, exc)
        return False

    if not _has_audio_magic_bytes(head):
        log.warning(
            "[%s] validate: %s не похоже на аудио (header=%r), удаляю",
            source, path.name, head,
        )
        _safe_unlink(path)
        return False

    return True


def _safe_unlink(path: Path) -> None:
    """Удаление файла без exception если уже нет."""
    try:
        path.unlink()
    except OSError:
        pass


# Минимальная длительность «полного» трека в секундах. Всё что короче —
# preview / radio-edit / snippet / 30-секундный Deezer preview.
DEFAULT_MIN_FULL_DURATION_SEC = 90
# Жёсткий порог: всё короче этого — гарантированно preview, удаляем.
PREVIEW_HARD_MAX_SEC = 45


def validate_full_track(
    path: Path,
    *,
    source: str = "unknown",
    min_duration_sec: int = DEFAULT_MIN_FULL_DURATION_SEC,
) -> bool:
    """Проверяет что файл — полноценный трек (не preview / radio-edit / snippet).

    Сначала читает duration через mutagen. Если duration не определяется —
    возвращает False (не доверяем). Если duration <= PREVIEW_HARD_MAX_SEC
    (45с) — удаляем файл и возвращаем False. Если 45 < duration <
    min_duration_sec — оставляем файл (для metadata/cover) но возвращаем
    False — провайдер должен решить сам что делать.

    Этот валидатор НЕ заменяет validate_audio_file — он проверяет ТОЛЬКО
    длительность. Используется ВТОРЫМ слоем после magic-bytes-валидации.

    Параметры:
        path: путь к аудио-файлу (должен уже пройти validate_audio_file)
        source: имя провайдера для логов
        min_duration_sec: минимальная длительность для «полного» трека

    Возвращает True если duration >= min_duration_sec.
    """
    if not path.exists():
        return False

    try:
        from mutagen import File as MutagenFile  # type: ignore
        m = MutagenFile(str(path))
        duration: float | None = None
        if m is not None and m.info is not None:
            d = getattr(m.info, "length", None)
            if d:
                duration = float(d)
    except Exception as exc:
        log.warning("[%s] full-track: mutagen failed для %s: %s", source, path.name, exc)
        return False

    if duration is None:
        log.warning(
            "[%s] full-track: %s — не удалось определить duration, не считаем full",
            source, path.name,
        )
        return False

    dur_int = int(duration)
    if dur_int <= PREVIEW_HARD_MAX_SEC:
        log.warning(
            "[%s] full-track: %s — preview/snippet (%dс <= %dс), УДАЛЯЮ",
            source, path.name, dur_int, PREVIEW_HARD_MAX_SEC,
        )
        _safe_unlink(path)
        return False

    if dur_int < min_duration_sec:
        log.info(
            "[%s] full-track: %s — короткий (%dс < %dс), оставляю файл но не full",
            source, path.name, dur_int, min_duration_sec,
        )
        return False

    return True


# Минимальный bitrate для "качественного" mp3. mp3party иногда отдаёт 128k
# или 96k версии — отсекаем. Для торрентов почти всегда 320, для YouTube Music
# Opus ~128 (но Opus 128 ≈ mp3 192 на слух, проверка не применяется к нему).
DEFAULT_MIN_BITRATE_KBPS = 192


def validate_min_bitrate(
    path: Path,
    *,
    source: str = "unknown",
    min_bitrate_kbps: int = DEFAULT_MIN_BITRATE_KBPS,
) -> bool:
    """Проверяет что mp3-файл имеет битрейт >= min. Через mutagen.

    True если bitrate >= min ИЛИ если bitrate не определяется (для opus/m4a
    битрейт обычно отображается, но если нет — не отклоняем).
    False (с удалением файла) — если bitrate определён и меньше порога.
    """
    if not path.exists():
        return False

    try:
        from mutagen import File as MutagenFile  # type: ignore
        m = MutagenFile(str(path))
        if m is None or m.info is None:
            return True
        br = getattr(m.info, "bitrate", None)
        if not br:
            return True
        bitrate_kbps = int(br) // 1000
    except Exception as exc:
        log.warning("[%s] bitrate-check: mutagen failed для %s: %s", source, path.name, exc)
        return True  # не отклоняем на всякий случай

    if bitrate_kbps < min_bitrate_kbps:
        log.warning(
            "[%s] bitrate-check: %s — %dk < %dk, удаляю",
            source, path.name, bitrate_kbps, min_bitrate_kbps,
        )
        _safe_unlink(path)
        return False
    return True


# Проверка ID3-тегов: реально ли в файле то что мы запрашивали.
# Soulseek/SC/mp3party-юзеры могут залить любое аудио под именем
# «Michael Jackson - Beat It.mp3», но в ID3-тегах будет правда
# (например Cash Cash — Michael Jackson (The Beat Goes On) — клубный
# трек 2013 года в сборнике). Filename матчинг тут бесполезен —
# проверяем теги через mutagen.

import unicodedata as _ud


def _normalize_for_match(s: str) -> str:
    """Lowercase + strip diacritics + только буквы/цифры/пробелы."""
    s = s.lower().strip()
    s = _ud.normalize("NFKD", s)
    s = "".join(c for c in s if not _ud.combining(c))
    out = []
    for c in s:
        if c.isalnum() or c.isspace():
            out.append(c)
        else:
            out.append(" ")
    return _re.sub(r"\s+", " ", "".join(out)).strip()


def validate_id3_match(
    path: Path,
    expected_artist: str,
    expected_title: str,
    *,
    source: str = "unknown",
) -> bool:
    """Проверяет что ID3-теги артиста+названия в файле соответствуют тому
    что мы искали.

    Логика мягкая: достаточно чтобы хотя бы 1 «значимое» слово из
    expected_artist и хотя бы 1 значимое слово из expected_title
    встречалось в соответствующих тегах. «Значимое» = > 2 символов
    (исключаем артикли the/a/of/в/и/на/у/etc).

    Если ID3 нет совсем (m.tags is None) — возвращаем True (не отклоняем,
    могли скачать legitimately без тегов). Удаляем файл только если
    теги ЕСТЬ и в них однозначно ДРУГОЙ артист/трек.
    """
    if not path.exists():
        return False

    try:
        from mutagen import File as MutagenFile  # type: ignore
        from mutagen.easyid3 import EasyID3  # type: ignore

        m = MutagenFile(str(path))
        # Сначала EasyID3 (стандарт для mp3), fallback на общий tag-словарь
        tag_artist = ""
        tag_title = ""
        try:
            if str(path).lower().endswith(".mp3"):
                t = EasyID3(str(path))
                tag_artist = (t.get("artist") or [""])[0]
                tag_title = (t.get("title") or [""])[0]
        except Exception:
            pass
        if (not tag_artist or not tag_title) and m is not None and m.tags is not None:
            try:
                td = dict(m.tags)
                # mp4: '\xa9ART' / '\xa9nam', vorbis/flac: 'ARTIST' / 'TITLE'
                for k_artist in ("ARTIST", "\xa9ART", "artist"):
                    v = td.get(k_artist)
                    if v:
                        tag_artist = str(v[0] if isinstance(v, list) else v)
                        break
                for k_title in ("TITLE", "\xa9nam", "title"):
                    v = td.get(k_title)
                    if v:
                        tag_title = str(v[0] if isinstance(v, list) else v)
                        break
            except Exception:
                pass
    except Exception as exc:
        log.warning("[%s] id3-check: mutagen failed для %s: %s", source, path.name, exc)
        return True  # не отклоняем

    # Теги вообще отсутствуют — пропускаем (доверяем filename-матчингу
    # провайдера). Это нормальный кейс для рипов с торрентов.
    if not tag_artist and not tag_title:
        return True

    expected_a_words = {w for w in _normalize_for_match(expected_artist).split() if len(w) > 2}
    expected_t_words = {w for w in _normalize_for_match(expected_title).split() if len(w) > 2}
    tag_a_words = set(_normalize_for_match(tag_artist).split())
    tag_t_words = set(_normalize_for_match(tag_title).split())

    # Пересечение хотя бы одного значимого слова
    artist_ok = bool(expected_a_words & tag_a_words) if expected_a_words else True
    title_ok = bool(expected_t_words & tag_t_words) if expected_t_words else True

    if not artist_ok or not title_ok:
        log.warning(
            "[%s] id3-check: %s — теги не совпадают. "
            "Ожидали '%s — %s', в файле '%s — %s'. УДАЛЯЮ",
            source, path.name, expected_artist, expected_title,
            tag_artist, tag_title,
        )
        _safe_unlink(path)
        return False

    return True


# Quality/version-фильтр. ДВА фильтра (решение Алекса 16.06.2026):
#  - acquisition (download/search/album): is_quality_title — режет live/concert
#    + откровенный мусор; КАВЕРЫ и РЕМИКСЫ пропускает (они нужны).
#  - alternate-version guard: is_alternate_version — НЕ подсовывать ремикс/кавер/
#    live вместо запрошенного оригинала (union live+junk+alt).
# Списки синхронизированы с apps/api/src/quality/track-quality.ts (LIVE_WORDS/…)
# и apps/web/src/lib/format.ts. Страж: apps/api/tests/quality/bad-keywords-sync.test.ts.
import re as _re

_LIVE_WORDS = ("live", "concert", "концерт")
_LIVE_PHRASES = (
    "live at", "live in", "live from", "live session", "live performance",
    "from concert", "концертная версия", "запись с концерта", "с концерта", "выступление",
)
_JUNK_WORDS = (
    "karaoke", "караоке", "nightcore", "slowed", "instrumental", "инструментал",
    "минусовка", "demo", "rehearsal", "репетиция", "bootleg",
)
_JUNK_PHRASES = ("sped up", "speed up", "fan made", "фан-релиз", "фан релиз")
_ALT_WORDS = ("cover", "remix", "acoustic", "version", "кавер", "ремикс")
_ALT_PHRASES = ("radio edit", "extended mix", "club mix")

# Python re \b — юникод-осознанный для str, кириллица работает.
_LIVE_WORD_RE = _re.compile(r"\b(" + "|".join(_LIVE_WORDS) + r")\b", _re.IGNORECASE)
_LIVE_WORD_START_RE = _re.compile(r"^\s*(" + "|".join(_LIVE_WORDS) + r")\b", _re.IGNORECASE)
_JUNK_WORD_RE = _re.compile(r"\b(" + "|".join(_JUNK_WORDS) + r")\b", _re.IGNORECASE)
_ALT_WORD_RE = _re.compile(r"\b(" + "|".join(_ALT_WORDS) + r")\b", _re.IGNORECASE)
_BRACKET_RE = _re.compile(r"[(\[]([^)\]]*)[)\]]")


def _phrase_hit(lower: str, phrases: tuple[str, ...]) -> str | None:
    for p in phrases:
        if p in lower:
            return p
    return None


def _live_marker_hit(s: str | None) -> str | None:
    """Маркер live/concert с защитой от ложных: фраза, скобки «(Live)», либо
    суффикс «- Live …». «Live Is Life» (live — часть имени) → None."""
    if not s:
        return None
    lower = s.lower()
    ph = _phrase_hit(lower, _LIVE_PHRASES)
    if ph:
        return ph
    for m in _BRACKET_RE.finditer(s):
        mm = _LIVE_WORD_RE.search(m.group(1))
        if mm:
            return mm.group(1).lower()
    segs = _re.split(r"\s+[-–—|]\s+|:\s+", s)
    if len(segs) > 1:
        mm = _LIVE_WORD_START_RE.match(segs[-1])
        if mm:
            return mm.group(1).lower()
    return None


def is_quality_title(title: str) -> tuple[bool, str | None]:
    """ACQUISITION-фильтр (download/search/album): можно ли пускать трек.

    Режет live/concert-версии и откровенный мусор (karaoke/nightcore/slowed/
    instrumental/demo/bootleg/…). КАВЕРЫ и РЕМИКСЫ пропускает (True) — они нужны.
    """
    if not title:
        return True, None
    live = _live_marker_hit(title)
    if live:
        return False, f'live/concert version ("{live}")'
    m = _JUNK_WORD_RE.search(title)
    if m:
        return False, f'junk version ("{m.group(1)}")'
    jp = _phrase_hit(title.lower(), _JUNK_PHRASES)
    if jp:
        return False, f'junk version ("{jp}")'
    return True, None


def _hidden_marker(title: str | None) -> str | None:
    """UNION-маркер (live+junk+alt) — для is_alternate_version. Возвращает
    найденный токен или None. Каверы/ремиксы тоже считаются alt-маркером."""
    if not title:
        return None
    live = _live_marker_hit(title)
    if live:
        return live
    m = _JUNK_WORD_RE.search(title)
    if m:
        return m.group(1).lower()
    jp = _phrase_hit(title.lower(), _JUNK_PHRASES)
    if jp:
        return jp
    m = _ALT_WORD_RE.search(title)
    if m:
        return m.group(1).lower()
    ap = _phrase_hit(title.lower(), _ALT_PHRASES)
    if ap:
        return ap
    return None


# Допуск по длительности (сек) при сверке с эталоном из Яндекса. Ремиксы/edit'ы
# обычно отличаются сильнее; небольшая разница (тишина в конце, разный мастеринг)
# в пределах допуска — это та же версия.
DURATION_TOLERANCE_SEC = 8


def duration_off(actual_sec: int | float | None, expected_sec: int | float | None,
                 tol: int = DURATION_TOLERANCE_SEC) -> bool:
    """True если длительность кандидата отличается от эталона больше допуска.

    Если любая из величин неизвестна (None/0) — возвращает False (НЕ отбраковываем,
    эталон просто неприменим). Так фильтр включается только когда есть и эталон,
    и измеренная длина кандидата.
    """
    if not actual_sec or not expected_sec:
        return False
    return abs(int(actual_sec) - int(expected_sec)) > tol


def is_alternate_version(candidate_title: str, requested_title: str) -> tuple[bool, str | None]:
    """True если `candidate_title` — альтернативная версия (remix / slowed /
    live / cover / ...), которую мы НЕ запрашивали.

    Логика: если в названии кандидата есть bad-keyword (см. is_quality_title),
    но того же слова НЕТ в запрошенном названии — значит это ремикс/слоу/кавер
    под именем оригинала, его надо пропустить. Если же мы сами искали ремикс
    (в requested_title есть то же слово) — НЕ отклоняем.

    Используется провайдерами поиска (SoundCloud, YouTube Music) ДО скачивания:
    SoundCloud-перезаливы вида «HOLLYFLAME - Тону (Konkin remix)» матчатся по
    artist+title, но это не оригинал. Зеркалит логику youtube_music._is_clip_entry,
    но переиспользует общий keyword-список.
    """
    marker = _hidden_marker(candidate_title)
    if not marker:
        return False, None
    if marker.lower() in (requested_title or "").lower():
        # пользователь сам искал эту версию (напр. запрос «… remix») — разрешаем
        return False, None
    return True, f'alternate version ("{marker}")'


# Маркеры СБОРНИКА (various artists / топ / хиты / мегамикс). Правило (Алекс,
# 07.06.2026): с торрента качаем весь альбом ТОЛЬКО если это альбом ОДНОГО
# артиста; сборник — берём из него лишь нужный трек, не тащим всё как «альбом».
# ИЗМЕНЕНО 21.09.2026 (Alex TG 20293, «оставлять весь сборник как есть»): торрент-провайдеры теперь качают сборник ЦЕЛИКОМ,
# но запасным путём — после альбомов одного артиста (см. _filter_candidates), и оставляют его как есть.
# NB: «Лучшее»/«Best of» одного артиста — это его бест-оф, НЕ сборник, поэтому
# одиночного «лучшее» здесь НЕТ.
_COMPILATION_MARKERS = (
    "сборник", "compilation", "megamix", "mega mix", "дискотека", "новинки",
    "союз представляет", "russian hits", "russian top", " хиты ", " топ ",
    " чарт ", "chart hits", "клубные", "club hits", "best dance", "антолог",
    "antholog", "лучшие песни", "только хиты", " грани ", "100 хит", "50 хит",
)


def is_compilation_title(title: str) -> bool:
    """True если торрент/альбом — сборник РАЗНЫХ артистов (а не альбом одного).
    Тогда из него берём только запрошенный трек, а не весь как «альбом артиста»."""
    t = (title or "").lower()
    ts = t.strip()
    if ts.startswith("va ") or ts.startswith("va-") or ts.startswith("v.a") or "various artist" in t:
        return True
    # VA как отдельный токен не в начале: «(Soundtrack) VA - …», «VA (Баста, …) -»,
    # «(by VA)», «V/A». Требуем после VA тире или «(» — иначе ловили бы «Va Bank».
    if re.search(r"(?:^|[\s(\[])v\.?\s?a\b\s*[-_–—(]", t) or "(by va)" in t or "v/a" in t:
        return True
    return any(m in (" " + t + " ") for m in _COMPILATION_MARKERS)


def _extract_id3_title(path: Path) -> str:
    """Читает title из ID3-тегов через mutagen. Возвращает '' если не получилось.

    Отдельная функция для удобного мока в тестах (monkeypatch).
    """
    try:
        from mutagen import File as MutagenFile  # type: ignore
        from mutagen.easyid3 import EasyID3  # type: ignore

        tag_title = ""
        try:
            if str(path).lower().endswith(".mp3"):
                t = EasyID3(str(path))
                tag_title = (t.get("title") or [""])[0]
        except Exception:
            pass
        if not tag_title:
            m = MutagenFile(str(path))
            if m is not None and m.tags is not None:
                try:
                    td = dict(m.tags)
                    for k in ("TITLE", "\xa9nam", "title"):
                        v = td.get(k)
                        if v:
                            tag_title = str(v[0] if isinstance(v, list) else v)
                            break
                except Exception:
                    pass
        return tag_title or ""
    except Exception:
        return ""


def validate_quality_metadata(
    path: Path,
    soulseek_filename: str | None = None,
    *,
    source: str = "unknown",
) -> bool:
    """Проверяет ID3 title и Soulseek-filename на bad-keywords
    (remix / live / club mix / extended / karaoke / etc.).

    Закрывает дыру validate_id3_match: тот проверяет что в файле реально наш
    артист+название (по пересечению значимых слов), но НЕ ловит файл вида
    «Billie Jean (Cash Cash Club Mix)» — слова billie+jean есть, остальное
    игнорируется. Аплоадеры на Soulseek обычно честно подписывают ID3 (иначе
    их собственные библиотеки не находят трек), а filename часто содержит
    подсказку («DJ Top - Billie Jean Remix.mp3»).

    Если в ID3 title ИЛИ в basename(soulseek_filename) найден bad keyword —
    удаляет файл и возвращает False. Если mutagen не читается — пропускает
    проверку title и смотрит только filename. Если оба пусты — True.
    """
    if not path.exists():
        return False

    checks: list[tuple[str, str]] = []
    id3_title = _extract_id3_title(path)
    if id3_title:
        checks.append(("id3 title", id3_title))
    if soulseek_filename:
        checks.append(("filename", Path(soulseek_filename).name))

    for label, value in checks:
        ok, reason = is_quality_title(value)
        if not ok:
            log.warning(
                "[%s] quality-meta: %s — %s='%s' (%s), УДАЛЯЮ",
                source, path.name, label, value, reason,
            )
            _safe_unlink(path)
            return False

    return True

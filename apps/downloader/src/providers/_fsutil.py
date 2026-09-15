"""Имена файлов и нормализация ключей — общее для провайдеров (musify,
mp3party, торрент-альбомы). Раньше жило в soulseek_download.py; вынесено
сюда при переезде качалки на brain (Soulseek пока убран)."""
from __future__ import annotations

import re
import unicodedata
from pathlib import Path

_FORBIDDEN_FS_CHARS = re.compile(r'[<>:"/\\|?*\x00-\x1f]')


def normalize_key(s: str) -> str:
    """Нормализация для дедупликации: lowercase, без диакритики латиницы,
    только буквы (latin + cyrillic) и цифры. Кириллицу не транслитерируем."""
    s = s.lower().strip()
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = re.sub(r"[^\wЀ-ӿ]+", " ", s, flags=re.UNICODE)
    s = re.sub(r"\s+", " ", s).strip()
    return s


def make_filename(artist: str, title: str, ext: str = ".mp3") -> str:
    """«Artist - Title.mp3» с заменой запрещённых символов на _."""
    artist_clean = _FORBIDDEN_FS_CHARS.sub("_", artist).strip()
    title_clean = _FORBIDDEN_FS_CHARS.sub("_", title).strip()
    return f"{artist_clean} - {title_clean}{ext}"


def artist_subdir(cache_dir: Path, artist: str) -> Path:
    """Папка исполнителя внутри cache_dir — качалка кладёт найденные треки
    туда, а не плоским списком (Alex TG 15.09.2026: хочет как остальная его
    музыка на диске — разложено по папкам, не «yandex-12345.mp3» в одной
    куче). Создаёт папку, если её ещё нет."""
    artist_clean = _FORBIDDEN_FS_CHARS.sub("_", artist).strip() or "Unknown"
    d = cache_dir / artist_clean
    d.mkdir(parents=True, exist_ok=True)
    return d


def _file_matches(filename: str, artist_key: str, title_key: str) -> bool:
    """Каждое значимое слово (>=2 симв.) из artist_key И title_key должно
    встретиться в нормализованном имени файла — порядок не важен."""
    norm = normalize_key(filename)

    def all_words_present(key: str) -> bool:
        words = [w for w in key.split() if len(w) >= 2]
        if not words:
            return True
        return all(w in norm for w in words)

    return all_words_present(artist_key) and all_words_present(title_key)

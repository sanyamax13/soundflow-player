from __future__ import annotations
import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

# Загружаем .env из директории python-sidecar явно (cwd может быть другим).
_HERE = Path(__file__).resolve().parent.parent
load_dotenv(_HERE / ".env", override=True)


def swap_root(path: str | None, from_root: Path, to_root: Path) -> str | None:
    """Переписать корневой префикс пути с `from_root` на `to_root`.

    Stage 2 path translation: sidecar на fg физически пишет в local
    (D:\\SoundFlow\\*), но API/БД на brain хранят canonical (E:\\soundflow-data\\*).
    Эта функция меняет только строковый префикс, сохраняя относительный хвост
    в оригинальном регистре.

    Правила:
      - None → None
      - from_root == to_root (по нормализованному регистронезависимому виду) →
        path без изменений (no-op на brain, где local == canonical)
      - path внутри from_root → префикс заменён на to_root
      - path вне from_root → path без изменений (passthrough)

    ВАЖНО: symlink НЕ резолвится (`.resolve()` не вызывается). На brain
    E:\\soundflow-data — это symlink на \\\\fg\\soundflow; разворот сломал бы
    инвариант canonical-путей. Сравнение регистронезависимо (Windows fs).
    """
    if path is None:
        return None
    base = os.path.normpath(str(from_root))
    dest = os.path.normpath(str(to_root))
    if os.path.normcase(base) == os.path.normcase(dest):
        return path
    p_norm = os.path.normpath(path)
    if os.path.normcase(p_norm) == os.path.normcase(base):
        return str(to_root)
    prefix = base + os.sep
    if os.path.normcase(p_norm).startswith(os.path.normcase(prefix)):
        rel = p_norm[len(prefix):]
        return str(Path(to_root) / rel)
    return path


@dataclass(frozen=True)
class Config:
    sidecar_port: int
    sidecar_host: str  # интерфейс прослушивания. brain: 127.0.0.1 (default). fg Stage 2: 0.0.0.0
    bgutil_url: str
    log_level: str
    slskd_url: str
    slskd_api_key: str
    slskd_downloads_dir: Path  # хост-путь куда slskd кладёт файлы (через bind-mount /app/downloads)
    track_cache_dir: Path  # LOCAL physical: куда sidecar реально пишет кеш
    yt_cookies_browser: str  # 'chrome' | 'firefox' | 'edge' | '' для отключения
    qbt_host: str
    qbt_port: int
    qbt_user: str
    qbt_pass: str
    albums_dir: Path  # LOCAL physical: куда qBittorrent кладёт скачанные альбомы
    tapochek_user: str
    tapochek_pass: str
    rutracker_user: str
    rutracker_pass: str
    rutracker_cookie: str  # "bb_session=...; bb_data=..." из браузера: вход требует капчу
    nnmclub_cookie: str  # "phpbb2mysql_4_data=...; phpbb2mysql_4_sid=..." из браузера (капча)
    rustorka_cookie: str  # "bb_session=...; bb_ssl=..." из браузера (TorrentPier)
    # CANONICAL paths которые sidecar возвращает API (БД хранит их as-is).
    # На brain == local (no-op). На fg: local=D:\SoundFlow\*, canonical=E:\soundflow-data\*.
    canonical_cache_dir: Path
    canonical_albums_dir: Path

    def to_canonical(self, path: str | None) -> str | None:
        """LOCAL physical path → CANONICAL path для ответа API (file_path в БД).

        Применяется к путям которые sidecar ВОЗВРАЩАЕТ API (/find-audio,
        extra_tracks, /soulseek/find-and-download). Пробует cache-, затем
        albums-маппинг. Путь вне обоих dirs возвращается как есть.
        """
        if path is None:
            return None
        out = swap_root(path, self.track_cache_dir, self.canonical_cache_dir)
        if out != path:
            return out
        return swap_root(path, self.albums_dir, self.canonical_albums_dir)

    def to_local(self, path: str | None) -> str | None:
        """CANONICAL path → LOCAL physical path для чтения файла на fg.

        Применяется к путям которые API ПЕРЕДАЁТ sidecar'у на вход
        (/analyze-features, /analyze-loudness) — API хранит canonical E:\\...,
        а sidecar на fg должен открыть файл по local D:\\SoundFlow\\...
        На brain это no-op (canonical == local).
        """
        if path is None:
            return None
        out = swap_root(path, self.canonical_cache_dir, self.track_cache_dir)
        if out != path:
            return out
        return swap_root(path, self.canonical_albums_dir, self.albums_dir)

    @classmethod
    def from_env(cls) -> "Config":
        # LOCAL physical dirs — куда sidecar/qBT реально пишут.
        # На brain = E:\soundflow-data\* (symlink на fg). На fg = D:\SoundFlow\*.
        track_cache = Path(
            os.environ.get("TRACK_CACHE_DIR", r"E:\soundflow-data\cache")
        )
        albums = Path(os.environ.get("ALBUMS_DIR", r"E:\soundflow-data\music"))
        # CANONICAL dirs — что возвращаем API (БД хранит as-is). Если env не
        # задан → equals local → translation полностью no-op (режим brain).
        canonical_cache_env = os.environ.get("CANONICAL_CACHE_DIR")
        canonical_albums_env = os.environ.get("CANONICAL_ALBUMS_DIR")
        return cls(
            sidecar_port=int(os.environ.get("SIDECAR_PORT", "8001")),
            sidecar_host=os.environ.get("SIDECAR_HOST", "127.0.0.1"),
            bgutil_url=os.environ.get("BGUTIL_URL", "http://127.0.0.1:4416"),
            log_level=os.environ.get("LOG_LEVEL", "INFO"),
            slskd_url=os.environ.get("SLSKD_URL", "http://127.0.0.1:5030"),
            slskd_api_key=os.environ.get("SLSKD_API_KEY", ""),
            slskd_downloads_dir=Path(
                os.environ.get(
                    "SLSKD_DOWNLOADS_DIR",
                    str(_HERE.parent.parent / "slskd-config" / "downloads"),
                )
            ),
            track_cache_dir=track_cache,
            yt_cookies_browser=os.environ.get("YT_COOKIES_BROWSER", "chrome"),
            qbt_host=os.environ.get("QBT_HOST", "127.0.0.1"),
            qbt_port=int(os.environ.get("QBT_PORT", "8080")),
            qbt_user=os.environ.get("QBT_USER", ""),
            qbt_pass=os.environ.get("QBT_PASS", ""),
            albums_dir=albums,
            tapochek_user=os.environ.get("TAPOCHEK_USER", ""),
            tapochek_pass=os.environ.get("TAPOCHEK_PASS", ""),
            rutracker_user=os.environ.get("RUTRACKER_USER", ""),
            rutracker_pass=os.environ.get("RUTRACKER_PASS", ""),
            rutracker_cookie=os.environ.get("RUTRACKER_COOKIE", ""),
            nnmclub_cookie=os.environ.get("NNMCLUB_COOKIE", ""),
            rustorka_cookie=os.environ.get("RUSTORKA_COOKIE", ""),
            canonical_cache_dir=(
                Path(canonical_cache_env) if canonical_cache_env else track_cache
            ),
            canonical_albums_dir=(
                Path(canonical_albums_env) if canonical_albums_env else albums
            ),
        )


config = Config.from_env()

"""Раскладка торрент-альбомов одного исполнителя по папкам исполнителей (Alex TG 20295, 21.09.2026, вариант «2»).

Альбом одного исполнителя ложится в `<корень музыки>\\<Исполнитель>\\<раздача>` (без «Торренты»), сборник разных
исполнителей — в папку альбомов. В папке исполнителя уже может лежать музыка Alex, поэтому: раздачу без своей папки
или с уже существующей одноимённой папкой не берём (проверка до скачивания, торрент убирается БЕЗ удаления файлов);
папку исполнителя никогда не сканируем (сканер стирает «плохие» mp3) и не удаляем.
"""
from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import pytest

from src.providers import nnmclub_album as nnm
from src.providers import rutor_album as rutor
from src.providers import rutracker_album as ra
from src.providers import tapochek_album as tp

MB = 1024 * 1024


class _FakeClock:
    def __init__(self) -> None:
        self.now = 1_000_000.0

    def time(self) -> float:
        return self.now

    def sleep(self, sec: float) -> None:
        self.now += sec


class _Item(dict):
    """Торрент из qBittorrent: и `t.hash`, и `t["hash"]`, и `t.get(...)`."""

    def __getattr__(self, k):
        return self[k]


class _FakeQbt:
    def __init__(self, existing=()) -> None:
        self.added: list[dict] = []
        self.deleted: list[tuple] = []
        self._items = [_Item(x) for x in existing]
        self.torrent_categories = SimpleNamespace(create_category=lambda **kw: None)
        self.torrents = SimpleNamespace(
            add=self._add, info=self._info, delete=self._delete,
            start=lambda **kw: None, stop=lambda **kw: None,
        )

    def auth_log_in(self) -> None:
        pass

    def _add(self, **kw) -> None:
        self.added.append(kw)
        self._items.append(_Item(hash=f"h{len(self._items) + 1}", content_path=""))

    def _info(self, **kw):
        return list(self._items)

    def _delete(self, torrent_hashes=None, delete_files=None) -> None:
        self.deleted.append((torrent_hashes, delete_files))


def _cfg(tmp_path: Path, artist_root: bool = True):
    music = tmp_path / "Музыка"
    return SimpleNamespace(
        qbt_user="u", qbt_pass="p",
        albums_dir=music / "Торренты",
        albums_artist_root=music if artist_root else None,
    )


ALBUM_FILES = [{"name": "Placebo - Meds (2006)/01 Meds.mp3"}, {"name": "Placebo - Meds (2006)/02 Infra-red.mp3"}]


# ---------------------------------------------------------------- имя папки исполнителя
@pytest.mark.parametrize("artist,want", [
    ("Placebo", "Placebo"),
    ("Aarne, Toxi$ & Big Baby Tape", "Aarne"),
    ("AC/DC", "AC_DC"),
    ("Some More?", "Some More_"),
    ("  Depeche   Mode ", "Depeche Mode"),
    ("Sting.", "Sting"),
    ("CON", ""),
    ("nul.txt", ""),
    ("???", ""),
    ("...", ""),
    ("", ""),
])
def test_artist_folder_name(artist, want):
    assert ra.artist_folder_name(artist) == want


def test_artist_folder_name_is_short():
    assert len(ra.artist_folder_name("A" * 300)) == 100


# ---------------------------------------------------------------- куда ложится раздача
def test_album_of_one_artist_goes_to_artist_folder(monkeypatch, tmp_path):
    cfg = _cfg(tmp_path)
    monkeypatch.setattr(ra, "config", cfg)
    assert ra.album_save_dir("Placebo", "Placebo - Meds (2006) MP3 320") == cfg.albums_artist_root / "Placebo"


def test_compilation_stays_in_albums_dir(monkeypatch, tmp_path):
    cfg = _cfg(tmp_path)
    monkeypatch.setattr(ra, "config", cfg)
    assert ra.album_save_dir("Placebo", "VA - Best Of Rock 2020 (2 CD) MP3 320 Placebo") == cfg.albums_dir


def test_layout_off_without_artist_root_or_name(monkeypatch, tmp_path):
    monkeypatch.setattr(ra, "config", _cfg(tmp_path, artist_root=False))
    assert ra.album_save_dir("Placebo", "Placebo - Meds (2006) MP3 320") == ra.config.albums_dir
    monkeypatch.setattr(ra, "config", _cfg(tmp_path))
    assert ra.album_save_dir("???", "Placebo - Meds (2006) MP3 320") == ra.config.albums_dir


def test_artist_named_like_albums_folder_is_not_its_own_folder(monkeypatch, tmp_path):
    cfg = _cfg(tmp_path)
    monkeypatch.setattr(ra, "config", cfg)
    assert ra.album_save_dir("Торренты", "Торренты - Альбом MP3 320") == cfg.albums_dir


# ---------------------------------------------------------------- проверка раздачи до скачивания
def test_layout_problem_none_for_clean_album(monkeypatch, tmp_path):
    cfg = _cfg(tmp_path)
    monkeypatch.setattr(ra, "config", cfg)
    assert ra.torrent_layout_problem(cfg.albums_artist_root / "Placebo", ALBUM_FILES) is None


def test_layout_problem_is_off_in_albums_dir(monkeypatch, tmp_path):
    cfg = _cfg(tmp_path)
    monkeypatch.setattr(ra, "config", cfg)
    (cfg.albums_dir / "Placebo - Meds (2006)").mkdir(parents=True)
    assert ra.torrent_layout_problem(cfg.albums_dir, [{"name": "01.mp3"}]) is None


def test_layout_problem_single_file_or_no_common_folder(monkeypatch, tmp_path):
    cfg = _cfg(tmp_path)
    monkeypatch.setattr(ra, "config", cfg)
    save = cfg.albums_artist_root / "Placebo"
    assert ra.torrent_layout_problem(save, [{"name": "Meds.mp3"}])
    assert ra.torrent_layout_problem(save, [{"name": "A/01.mp3"}, {"name": "B/02.mp3"}])
    assert ra.torrent_layout_problem(save, [{"name": "A/01.mp3"}, {"name": "02.mp3"}])
    assert ra.torrent_layout_problem(save, [])


def test_layout_problem_when_folder_already_exists(monkeypatch, tmp_path):
    cfg = _cfg(tmp_path)
    monkeypatch.setattr(ra, "config", cfg)
    save = cfg.albums_artist_root / "Placebo"
    (save / "Placebo - Meds (2006)").mkdir(parents=True)
    assert "уже есть" in ra.torrent_layout_problem(save, ALBUM_FILES)
    assert ra.torrent_layout_problem(save, [{"name": "Другая раздача/01.mp3"}]) is None


# ---------------------------------------------------------------- папка альбома
def test_album_dir_is_the_torrent_folder(monkeypatch, tmp_path):
    cfg = _cfg(tmp_path)
    monkeypatch.setattr(ra, "config", cfg)
    save = cfg.albums_artist_root / "Placebo"
    inside = save / "Placebo - Meds (2006)"
    assert ra.torrent_album_dir({"content_path": str(inside)}, save) == inside


def test_album_dir_never_the_artist_folder_itself(monkeypatch, tmp_path):
    cfg = _cfg(tmp_path)
    monkeypatch.setattr(ra, "config", cfg)
    save = cfg.albums_artist_root / "Placebo"
    save.mkdir(parents=True)
    single = save / "Meds.mp3"
    single.write_bytes(b"x")
    assert ra.torrent_album_dir({"content_path": str(save)}, save) is None
    assert ra.torrent_album_dir({"content_path": str(single)}, save) is None
    assert ra.torrent_album_dir({"save_path": str(save)}, save) is None


def test_album_dir_in_albums_dir_keeps_old_behaviour(monkeypatch, tmp_path):
    cfg = _cfg(tmp_path)
    monkeypatch.setattr(ra, "config", cfg)
    cfg.albums_dir.mkdir(parents=True)
    single = cfg.albums_dir / "Mix.mp3"
    single.write_bytes(b"x")
    assert ra.torrent_album_dir({"content_path": str(single)}, cfg.albums_dir) == cfg.albums_dir


# ---------------------------------------------------------------- стирание не подошедшего альбома
def test_discard_deletes_only_the_matching_torrent_and_empty_artist_folder(monkeypatch, tmp_path):
    cfg = _cfg(tmp_path)
    monkeypatch.setattr(ra, "config", cfg)
    artist_dir = cfg.albums_artist_root / "Placebo"
    album = artist_dir / "Placebo - Meds (2006)"
    album.mkdir(parents=True)
    qbt = _FakeQbt(existing=[
        {"hash": "aa", "content_path": str(album)},
        {"hash": "bb", "content_path": str(artist_dir / "Другой альбом")},
    ])
    monkeypatch.setattr(ra, "_qbt_client", lambda: qbt)
    clock = _FakeClock()
    monkeypatch.setattr(ra, "time", clock)
    album.rmdir()  # qBittorrent убрал файлы и папку раздачи
    ra.discard_album(str(album))
    assert qbt.deleted == [("aa", True)]
    assert not artist_dir.exists()


def test_discard_keeps_artist_folder_with_other_music(monkeypatch, tmp_path):
    cfg = _cfg(tmp_path)
    monkeypatch.setattr(ra, "config", cfg)
    artist_dir = cfg.albums_artist_root / "Placebo"
    album = artist_dir / "Placebo - Meds (2006)"
    album.mkdir(parents=True)
    (artist_dir / "Моя песня.mp3").write_bytes(b"x")
    qbt = _FakeQbt(existing=[{"hash": "aa", "content_path": str(album)}])
    monkeypatch.setattr(ra, "_qbt_client", lambda: qbt)
    monkeypatch.setattr(ra, "time", _FakeClock())
    ra.discard_album(str(album))
    assert (artist_dir / "Моя песня.mp3").exists()


def test_discard_never_touches_music_root_or_albums_dir(monkeypatch, tmp_path):
    cfg = _cfg(tmp_path)
    monkeypatch.setattr(ra, "config", cfg)

    def boom():
        raise AssertionError("qBittorrent не должен вызываться")

    monkeypatch.setattr(ra, "_qbt_client", boom)
    ra.discard_album(str(cfg.albums_artist_root))
    ra.discard_album(str(cfg.albums_dir))
    ra.discard_album("")


# ---------------------------------------------------------------- пустая папка исполнителя после неудачи
def test_sweep_removes_empty_artist_folder_only(monkeypatch, tmp_path):
    cfg = _cfg(tmp_path)
    monkeypatch.setattr(ra, "config", cfg)
    monkeypatch.setattr(ra, "time", _FakeClock())
    empty = cfg.albums_artist_root / "Placebo"
    empty.mkdir(parents=True)
    full = cfg.albums_artist_root / "Muse"
    full.mkdir()
    (full / "a.mp3").write_bytes(b"x")
    ra.sweep_empty_artist_dir("Placebo")
    ra.sweep_empty_artist_dir("Muse")
    ra.sweep_empty_artist_dir("Нет такого")
    ra.sweep_empty_artist_dir("Торренты")  # папка альбомов — не «папка исполнителя»
    assert not empty.exists()
    assert (full / "a.mp3").exists()


def test_sweep_off_without_artist_root(monkeypatch, tmp_path):
    cfg = _cfg(tmp_path, artist_root=False)
    monkeypatch.setattr(ra, "config", cfg)
    d = tmp_path / "Музыка" / "Placebo"
    d.mkdir(parents=True)
    ra.sweep_empty_artist_dir("Placebo")
    assert d.exists()


# ---------------------------------------------------------------- сквозной прогон провайдеров с поддельными сетью и qBittorrent
def _wire(monkeypatch, tmp_path, mod, files, content_path, title="Placebo - Meds (2006) MP3 320"):
    """Провайдер целиком, но без сети/qBittorrent. Возвращает (qbt, cfg, вызовы сканера)."""
    cfg = _cfg(tmp_path)
    qbt = _FakeQbt()
    scans: list[Path] = []
    cand = {"title": title, "size_bytes": 120 * MB, "seeders": 5,
            "topic_url": "http://t/1", "download_id": "1", "torrent_url": "http://t/1.torrent"}
    monkeypatch.setattr(ra, "config", cfg)
    monkeypatch.setattr(mod, "config", cfg)
    monkeypatch.setattr(mod, "time", _FakeClock())
    monkeypatch.setattr(mod, "_qbt_client", lambda: qbt)
    monkeypatch.setattr(mod, "_wait_torrent_metadata", lambda q, h: files)
    monkeypatch.setattr(mod, "_wait_torrent_complete", lambda q, h, max_sec=None: {"content_path": content_path(cfg)})
    monkeypatch.setattr(mod, "_read_album_tracks", lambda d: scans.append(d) or [SimpleNamespace(file_path=str(d / "01 Meds.mp3"))])
    monkeypatch.setattr(mod, "_find_target_track", lambda tracks, a, t: tracks[0])
    if mod is nnm:
        monkeypatch.setattr(mod, "_ensure_session", lambda: object())
        monkeypatch.setattr(mod, "_do_search", lambda s, a: [cand])
        monkeypatch.setattr(mod, "_download_torrent_bytes", lambda s, i: b"d")
    else:
        monkeypatch.setattr(mod, "_do_search", lambda a: [cand])
        monkeypatch.setattr(mod, "_download_torrent_bytes", lambda u: b"d")
    return qbt, cfg, scans


@pytest.mark.parametrize("mod", [nnm, rutor])
def test_provider_puts_album_into_artist_folder(monkeypatch, tmp_path, mod):
    qbt, cfg, scans = _wire(
        monkeypatch, tmp_path, mod, ALBUM_FILES,
        lambda c: str(c.albums_artist_root / "Placebo" / "Placebo - Meds (2006)"),
    )
    res = mod._do_find_and_download("Placebo", "Meds")
    assert res is not None
    assert qbt.added[0]["save_path"] == str(cfg.albums_artist_root / "Placebo")
    assert qbt.added[0]["content_layout"] == "Original" and qbt.added[0]["is_paused"] is True
    assert res.album_dir == str(cfg.albums_artist_root / "Placebo" / "Placebo - Meds (2006)")
    assert scans == [cfg.albums_artist_root / "Placebo" / "Placebo - Meds (2006)"]
    assert qbt.deleted == []


@pytest.mark.parametrize("mod", [nnm, rutor])
def test_provider_puts_compilation_into_albums_dir(monkeypatch, tmp_path, mod):
    qbt, cfg, scans = _wire(
        monkeypatch, tmp_path, mod, [{"name": "VA - Best Of Rock 2020/01 Meds.mp3"}],
        lambda c: str(c.albums_dir / "VA - Best Of Rock 2020"),
        title="VA - Best Of Rock 2020 (2 CD) MP3 320 Placebo",
    )
    res = mod._do_find_and_download("Placebo", "Meds")
    assert res is not None
    assert qbt.added[0]["save_path"] == str(cfg.albums_dir)
    assert res.album_dir == str(cfg.albums_dir / "VA - Best Of Rock 2020")


@pytest.mark.parametrize("mod", [nnm, rutor])
def test_provider_refuses_existing_folder_without_deleting_files(monkeypatch, tmp_path, mod):
    qbt, cfg, scans = _wire(
        monkeypatch, tmp_path, mod, ALBUM_FILES,
        lambda c: str(c.albums_artist_root / "Placebo" / "Placebo - Meds (2006)"),
    )
    mine = cfg.albums_artist_root / "Placebo" / "Placebo - Meds (2006)"
    mine.mkdir(parents=True)
    (mine / "01 Meds.mp3").write_bytes(b"my own file")
    assert mod._do_find_and_download("Placebo", "Meds") is None
    assert qbt.deleted and all(flag is False for _, flag in qbt.deleted)  # файлы Alex не стираем
    assert scans == []
    assert (mine / "01 Meds.mp3").read_bytes() == b"my own file"


@pytest.mark.parametrize("mod", [nnm, rutor])
def test_provider_refuses_torrent_without_own_folder(monkeypatch, tmp_path, mod):
    qbt, cfg, scans = _wire(
        monkeypatch, tmp_path, mod, [{"name": "01 Meds.mp3"}, {"name": "02 Infra-red.mp3"}],
        lambda c: str(c.albums_artist_root / "Placebo"),
    )
    assert mod._do_find_and_download("Placebo", "Meds") is None
    assert qbt.deleted and all(flag is False for _, flag in qbt.deleted)
    assert scans == []


@pytest.mark.parametrize("mod", [nnm, rutor])
def test_provider_never_scans_artist_folder(monkeypatch, tmp_path, mod):
    """Метаданные выглядели прилично, но qBittorrent выложил файлы прямо в папку исполнителя — сканер не пускаем."""
    qbt, cfg, scans = _wire(
        monkeypatch, tmp_path, mod, ALBUM_FILES,
        lambda c: str(c.albums_artist_root / "Placebo"),
    )
    assert mod._do_find_and_download("Placebo", "Meds") is None
    assert scans == []
    assert qbt.deleted == []


def test_rutracker_and_tapochek_use_same_helpers():
    assert tp.album_save_dir is ra.album_save_dir
    assert tp.torrent_layout_problem is ra.torrent_layout_problem
    assert tp.torrent_album_dir is ra.torrent_album_dir
    assert tp.forget_torrent is ra.forget_torrent
    assert tp.sweep_empty_artist_dir is ra.sweep_empty_artist_dir
    assert nnm.album_save_dir is ra.album_save_dir and rutor.album_save_dir is ra.album_save_dir


def test_config_reads_artist_root_from_env(monkeypatch):
    import os

    from src.config import Config

    monkeypatch.setattr(os, "environ", {**os.environ, "ALBUMS_ARTIST_ROOT": r"G:\Музыка"})
    assert Config.from_env().albums_artist_root == Path(r"G:\Музыка")
    monkeypatch.setattr(os, "environ", {k: v for k, v in os.environ.items() if k != "ALBUMS_ARTIST_ROOT"})
    assert Config.from_env().albums_artist_root is None

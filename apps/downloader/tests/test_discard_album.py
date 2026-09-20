"""discard_album: не подошедший альбом стирается вместе с торрентом (21.09.2026).

Торренты пишутся в папку с музыкой, а её сканирует программа: оставшийся отвергнутый альбом попал бы в
каталог. Трогаем только торрент нашей категории с содержимым ровно в этой папке; папку альбомов — никогда.
"""
from __future__ import annotations

import os
from types import SimpleNamespace

from src.providers import rutracker_album as ra

ALBUMS = os.path.join("G:\\", "музыка", "Торренты")


class _FakeQbt:
    def __init__(self, torrents):
        self._torrents = torrents
        self.deleted = []
        self.torrents = SimpleNamespace(info=self._info, delete=self._delete)

    def _info(self, category=None):
        return [t for t in self._torrents if t.get("category") == category]

    def _delete(self, torrent_hashes=None, delete_files=False):
        self.deleted.append((torrent_hashes, delete_files))


def _setup(monkeypatch, torrents):
    fake = _FakeQbt(torrents)
    monkeypatch.setattr(ra, "_qbt_client", lambda: fake)
    monkeypatch.setattr(ra, "config", SimpleNamespace(albums_dir=ALBUMS))
    return fake


def _t(h, name, category=ra.QBT_CATEGORY):
    return {"hash": h, "category": category, "content_path": os.path.join(ALBUMS, name)}


def test_deletes_only_matching_torrent_with_files(monkeypatch):
    fake = _setup(monkeypatch, [_t("aaa", "Album A"), _t("bbb", "Album B")])
    ra.discard_album(os.path.join(ALBUMS, "Album A"))
    assert fake.deleted == [("aaa", True)]


def test_ignores_other_categories(monkeypatch):
    # личный торрент Alex (без нашей категории) с тем же путём не трогаем
    fake = _setup(monkeypatch, [_t("mine", "Album A", category="")])
    ra.discard_album(os.path.join(ALBUMS, "Album A"))
    assert fake.deleted == []


def test_never_touches_albums_root(monkeypatch):
    fake = _setup(monkeypatch, [{"hash": "x", "category": ra.QBT_CATEGORY, "content_path": ALBUMS}])
    ra.discard_album(ALBUMS)
    assert fake.deleted == []


def test_empty_dir_and_client_failure_are_not_errors(monkeypatch):
    fake = _setup(monkeypatch, [_t("aaa", "Album A")])
    ra.discard_album("")
    assert fake.deleted == []

    def boom():
        raise RuntimeError("qBittorrent недоступен")

    monkeypatch.setattr(ra, "_qbt_client", boom)
    ra.discard_album(os.path.join(ALBUMS, "Album A"))  # не падает

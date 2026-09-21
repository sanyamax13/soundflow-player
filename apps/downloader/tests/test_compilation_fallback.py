"""Сборники разных артистов — запасной путь торрент-провайдеров (Alex TG 20293, 21.09.2026: «оставлять весь сборник как есть»).

Раньше сборник (VA, «Хиты…», мегамикс) пропускался целиком: из него брали лишь нужный трек, и только если он попадал
под лимит альбома 300 МБ. Теперь сборник качается ЦЕЛИКОМ и остаётся как есть, но запасным путём: сначала альбомы одного
артиста, потом сборники (до 1,2 ГБ), и ждём сборник дольше (пока байты прибывают, до COMPILATION_MAX_SEC).
"""
from __future__ import annotations

from types import SimpleNamespace

import pytest

from src.providers import nnmclub_album as nnm
from src.providers import rutor_album as rutor
from src.providers import rutracker_album as ra
from src.providers import tapochek_album as tp

MB = 1024 * 1024

ALBUM = {"title": "Placebo - Meds (2006) MP3 320", "size_bytes": 120 * MB, "seeders": 3}
COMP = {"title": "VA - Best Of Rock 2020 (2 CD) MP3 320 Placebo", "size_bytes": 700 * MB, "seeders": 50}
COMP_HUGE = {"title": "VA - Mega Hits Collection MP3 Placebo", "size_bytes": 2000 * MB, "seeders": 90}
COMP_FLAC = {"title": "VA - Something FLAC Placebo", "size_bytes": 400 * MB, "seeders": 9}
COMP_DEAD = {"title": "VA - Rock 2019 MP3 Placebo", "size_bytes": 300 * MB, "seeders": 0}


@pytest.mark.parametrize("mod", [nnm, rutor])
def test_album_first_then_compilation(mod):
    res = mod._filter_candidates([COMP, ALBUM, COMP_HUGE, COMP_FLAC, COMP_DEAD], "placebo")
    assert [r["title"] for r in res] == [ALBUM["title"], COMP["title"]]


@pytest.mark.parametrize("mod", [nnm, rutor])
def test_compilation_is_taken_when_there_is_no_album(mod):
    assert [r["title"] for r in mod._filter_candidates([COMP], "placebo")] == [COMP["title"]]


def test_rutracker_and_tapochek_share_the_filter():
    album = {"fileName": ALBUM["title"], "fileSize": 120 * MB, "nbSeeders": 3}
    comp = {"fileName": COMP["title"], "fileSize": 700 * MB, "nbSeeders": 50}
    huge = {"fileName": COMP_HUGE["title"], "fileSize": 2000 * MB, "nbSeeders": 90}
    res = ra._filter_candidates([comp, album, huge], "placebo")
    assert [r["fileName"] for r in res] == [album["fileName"], comp["fileName"]]
    assert tp._filter_candidates is ra._filter_candidates


def test_wait_limit_is_longer_only_for_compilations():
    assert ra._wait_limit(COMP) == float(ra.COMPILATION_MAX_SEC)
    assert ra._wait_limit({"fileName": COMP["title"]}) == float(ra.COMPILATION_MAX_SEC)
    assert ra._wait_limit(ALBUM) is None
    assert ra._wait_limit({"fileName": ALBUM["title"]}) is None
    assert nnm._wait_limit is ra._wait_limit and rutor._wait_limit is ra._wait_limit and tp._wait_limit is ra._wait_limit


class _FakeClock:
    def __init__(self) -> None:
        self.now = 1_000_000.0

    def time(self) -> float:
        return self.now

    def sleep(self, sec: float) -> None:
        self.now += sec


def _endless_download(monkeypatch, max_sec):
    clock = _FakeClock()
    t0 = clock.now
    monkeypatch.setattr(ra, "time", clock)

    def info(torrent_hashes=None):
        t = clock.now - t0
        return [{"state": "downloading", "progress": 0.5, "downloaded": int(t) * 300_000,
                 "num_seeds": 2, "num_complete": 2, "dlspeed": 500_000}]

    qbt = SimpleNamespace(torrents=SimpleNamespace(info=info))
    res = ra._wait_torrent_complete(qbt, "abc", max_sec) if max_sec else ra._wait_torrent_complete(qbt, "abc")
    return res, clock.now - t0


def test_endless_download_stops_at_album_cap_by_default(monkeypatch):
    res, waited = _endless_download(monkeypatch, None)
    assert res is None
    assert ra.DOWNLOAD_MAX_SEC <= waited <= ra.DOWNLOAD_MAX_SEC + 2 * ra.POLL_INTERVAL_SEC


def test_compilation_download_is_awaited_longer(monkeypatch):
    res, waited = _endless_download(monkeypatch, float(ra.COMPILATION_MAX_SEC))
    assert res is None
    assert ra.COMPILATION_MAX_SEC <= waited <= ra.COMPILATION_MAX_SEC + 2 * ra.POLL_INTERVAL_SEC
    assert waited > ra.DOWNLOAD_MAX_SEC

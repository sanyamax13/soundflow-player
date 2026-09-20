"""_wait_torrent_complete: живая медленная закачка не убивается по базовому сроку (20.09.2026).

Альбом 128 МБ на 2 сидерах шёл нормально (58% за 3 минуты) и был убит на 240 с вместе с
недокачанными файлами. Теперь после базового срока ждём, пока байты прибывают, но не дольше
DOWNLOAD_MAX_SEC и не дольше TORRENT_STALL_SEC без нового байта. Время — поддельное, тест мгновенный.
"""
from __future__ import annotations

from types import SimpleNamespace

from src.providers import rutracker_album as ra


class _FakeClock:
    def __init__(self) -> None:
        self.now = 1_000_000.0

    def time(self) -> float:
        return self.now

    def sleep(self, sec: float) -> None:
        self.now += sec


class _FakeQbt:
    """qBittorrent: на каждый опрос отдаёт состояние по функции от прошедшего времени."""

    def __init__(self, clock: _FakeClock, state_at) -> None:
        self._clock = clock
        self._t0 = clock.now
        self._state_at = state_at
        self.torrents = SimpleNamespace(info=self._info)

    def _info(self, torrent_hashes=None):
        return [self._state_at(self._clock.now - self._t0)]


def _run(monkeypatch, state_at):
    clock = _FakeClock()
    monkeypatch.setattr(ra, "time", clock)
    qbt = _FakeQbt(clock, state_at)
    res = ra._wait_torrent_complete(qbt, "abc")
    return res, clock.now - qbt._t0


def _downloading(bytes_now, seeds=2):
    return {"state": "downloading", "progress": 0.5, "downloaded": bytes_now,
            "num_seeds": seeds, "num_complete": seeds, "dlspeed": 500_000}


def test_slow_but_alive_torrent_finishes_after_base_timeout(monkeypatch):
    # качается до 400-й секунды (дольше базовых 240), потом готово
    def state_at(t):
        if t >= 400:
            return {"state": "stalledUP", "progress": 1.0, "downloaded": int(t) * 300_000}
        return _downloading(int(t) * 300_000)

    res, waited = _run(monkeypatch, state_at)
    assert res is not None and res["progress"] == 1.0
    assert waited > ra.DOWNLOAD_TIMEOUT_SEC


def test_stalled_torrent_is_dropped_soon_after_base_timeout(monkeypatch):
    # байты растут до 200-й секунды, потом стоят: после базового срока ждём не больше STALL
    def state_at(t):
        return _downloading(int(min(t, 200)) * 300_000)

    res, waited = _run(monkeypatch, state_at)
    assert res is None
    assert ra.DOWNLOAD_TIMEOUT_SEC <= waited <= ra.DOWNLOAD_TIMEOUT_SEC + ra.TORRENT_STALL_SEC + 2 * ra.POLL_INTERVAL_SEC


def test_endless_slow_torrent_stops_at_hard_cap(monkeypatch):
    # байты растут вечно — но дольше DOWNLOAD_MAX_SEC не ждём
    res, waited = _run(monkeypatch, lambda t: _downloading(int(t) * 300_000))
    assert res is None
    assert ra.DOWNLOAD_MAX_SEC <= waited <= ra.DOWNLOAD_MAX_SEC + 2 * ra.POLL_INTERVAL_SEC


def test_dead_torrent_still_dropped_by_early_abort(monkeypatch):
    # ни сидеров, ни байт — рвётся по старому правилу «мёртвый», не ждёт базовый срок
    def state_at(t):
        return {"state": "metaDL", "progress": 0.0, "downloaded": 0, "num_seeds": 0,
                "num_complete": 0, "dlspeed": 0}

    res, waited = _run(monkeypatch, state_at)
    assert res is None
    assert waited < ra.DOWNLOAD_TIMEOUT_SEC

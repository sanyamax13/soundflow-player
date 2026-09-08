"""Чарт-эндпоинты сайдкара: парсеры публичных чартов (VK Top200, Яндекс,
TopHit, «Наше», Radio Record). Вынесены из main.py — это изолированная
группа: не зависит от аудио-цепочки и общих лимитов, каждый эндпоинт лениво
импортит свой парсер из .parsers и отдаёт результат. Подключается в main.py
через app.include_router(router) — пути и контракт остаются прежними."""
from __future__ import annotations

import logging

from fastapi import APIRouter
from pydantic import BaseModel

log = logging.getLogger("sidecar")
router = APIRouter()


class VkTop200Item(BaseModel):
    position: int
    title: str
    artist: str
    cover_url: str | None = None


class VkTop200Response(BaseModel):
    items: list[VkTop200Item]
    error: str | None = None


@router.post("/vk-top200", response_model=VkTop200Response)
async def vk_top200() -> VkTop200Response:
    """Парсит top200chart.ru через Playwright headless Chromium.
    Возвращает 200 треков с position/artist/title/cover_url.
    """
    try:
        from .parsers.vk_top200 import fetch_vk_top200
        items = await fetch_vk_top200()
        return VkTop200Response(items=[VkTop200Item(**i) for i in items])
    except Exception as e:
        log.warning("vk-top200 failed: %s", e)
        return VkTop200Response(items=[], error=str(e))


class YandexChartItem(BaseModel):
    position: int
    title: str
    artist: str
    cover_url: str | None = None
    external_url: str | None = None
    genre: str | None = None


class YandexChartRequest(BaseModel):
    chart_option: str = "russia"  # russia | world


class YandexChartResponse(BaseModel):
    items: list[YandexChartItem]
    error: str | None = None


@router.post("/yandex-chart", response_model=YandexChartResponse)
async def yandex_chart(req: YandexChartRequest) -> YandexChartResponse:
    """Возвращает Яндекс Music чарт через unofficial library MarshalX/yandex-music.
    Без OAuth-токена — публичная метадата доступна анонимно.
    """
    try:
        from .parsers.yandex_chart import fetch_yandex_chart
        items = fetch_yandex_chart(req.chart_option)
        return YandexChartResponse(items=[YandexChartItem(**i) for i in items])
    except Exception as e:
        log.warning("yandex-chart failed: %s", e)
        return YandexChartResponse(items=[], error=str(e))


class TopHitItem(BaseModel):
    position: int
    title: str
    artist: str
    language: str | None = None
    genres: list[str] = []
    track_id: str | None = None


class TopHitResponse(BaseModel):
    items: list[TopHitItem]
    error: str | None = None


@router.post("/tophit-chart", response_model=TopHitResponse)
async def tophit_chart() -> TopHitResponse:
    """Top-100 русских радио-хитов с tophit.ru с жанровыми тегами.
    Парсим HTML через BeautifulSoup. Источник для жанровых вкладок РФ.
    """
    try:
        from .parsers.top_hit import fetch_tophit_chart
        items = fetch_tophit_chart()
        return TopHitResponse(items=[TopHitItem(**i) for i in items])
    except Exception as e:
        log.warning("tophit-chart failed: %s", e)
        return TopHitResponse(items=[], error=str(e))


class RadioRecordItem(BaseModel):
    position: int
    title: str
    artist: str
    cover_url: str | None = None
    external_url: str | None = None


class RadioRecordResponse(BaseModel):
    items: list[RadioRecordItem]
    error: str | None = None


class NasheItem(BaseModel):
    position: int
    title: str
    artist: str
    cover_url: str | None = None
    external_url: str | None = None
    track_id: str | None = None


class NasheResponse(BaseModel):
    items: list[NasheItem]
    error: str | None = None


@router.post("/nashe-chartova", response_model=NasheResponse)
async def nashe_chartova() -> NasheResponse:
    """Russian rock weekly chart (Наше Радио — Чартова Дюжина).
    Источник для вкладки «Рок» в /charts country=ru.
    """
    try:
        from .parsers.nashe_chart import fetch_nashe_chartova
        items = fetch_nashe_chartova()
        return NasheResponse(items=[NasheItem(**i) for i in items])
    except Exception as e:
        log.warning("nashe-chartova failed: %s", e)
        return NasheResponse(items=[], error=str(e))


@router.post("/radio-record", response_model=RadioRecordResponse)
async def radio_record() -> RadioRecordResponse:
    """Live snapshot Radio Record (РФ электронное радио, ~50 каналов).
    Источник для вкладки «Электронная» в /charts.
    """
    try:
        from .parsers.radio_record import fetch_radio_record
        items = fetch_radio_record()
        return RadioRecordResponse(items=[RadioRecordItem(**i) for i in items])
    except Exception as e:
        log.warning("radio-record failed: %s", e)
        return RadioRecordResponse(items=[], error=str(e))

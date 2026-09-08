"""VK Top-200 parser via Playwright (top200chart.ru).

Используется sidecar endpoint /vk-top200.
"""
from __future__ import annotations
import asyncio
import logging
from typing import Any

URL = "https://www.top200chart.ru/"
log = logging.getLogger(__name__)


async def fetch_vk_top200() -> list[dict[str, Any]]:
    """Возвращает топ-200 VK с position, title, artist, cover_url.

    Сложность: top200chart.ru — Next.js SPA с infinite scroll. Используем
    Playwright headless с эмуляцией прокрутки.
    """
    from playwright.async_api import async_playwright  # type: ignore[import-untyped]

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        try:
            ctx = await browser.new_context(
                locale="ru-RU", viewport={"width": 1280, "height": 900}
            )
            page = await ctx.new_page()
            await page.goto(URL, wait_until="domcontentloaded", timeout=30000)
            await page.wait_for_timeout(2000)

            # Прокрутка до конца (infinite scroll)
            prev_height = 0
            for _ in range(40):
                await page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
                await page.wait_for_timeout(700)
                height = await page.evaluate("document.body.scrollHeight")
                if height == prev_height:
                    break
                prev_height = height

            tracks = await page.evaluate(
                """() => {
                    const rows = document.querySelectorAll('div.group.flex.items-center.gap-3.rounded-xl');
                    const out = [];
                    for (const row of rows) {
                        const text = row.innerText || '';
                        const posMatch = text.match(/^(\\d+)/);
                        if (!posMatch) continue;
                        const position = parseInt(posMatch[1], 10);
                        if (position < 1 || position > 200) continue;

                        const titleEl = row.querySelector('p.truncate.font-semibold');
                        const title = titleEl ? titleEl.innerText.trim() : '';

                        const artistEl = row.querySelector('p.truncate.text-xs');
                        const artist = artistEl ? artistEl.innerText.trim() : '';

                        if (!title || !artist) continue;

                        const img = row.querySelector('img');
                        const cover_url = img ? img.src : null;

                        out.push({ position, title, artist, cover_url });
                    }
                    return out;
                }"""
            )
        finally:
            await browser.close()

    # Уникальность по position
    seen = set()
    uniq = []
    for t in tracks:
        if t["position"] not in seen:
            seen.add(t["position"])
            uniq.append(t)
    log.info("vk-top200: parsed %d unique tracks", len(uniq))
    return uniq

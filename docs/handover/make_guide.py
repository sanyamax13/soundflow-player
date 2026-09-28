#!/usr/bin/env python3
"""Инструкция для второго человека (передача плеера, часть 6, 28.09.2026): собирает один HTML с картинками
внутри (можно переслать одним файлом) и PDF рядом.   python3 make_guide.py"""
import base64, pathlib, subprocess, sys

HERE = pathlib.Path(__file__).parent
SHOTS = HERE.parent / "handover-shots"


def img(name, w=640):
    b = base64.b64encode((SHOTS / name).read_bytes()).decode()
    return f'<img src="data:image/png;base64,{b}" style="max-width:{w}px">'


STEPS = f"""
<h1>SoundFlow — как поставить у себя</h1>
<p class="lead">Свой музыкальный плеер: музыка лежит на вашем компьютере, телефон играет её дома и вне дома.
Бесплатно, без подписок. Займёт около 20 минут.</p>

<div class="box"><b>Что понадобится</b>
<ul>
<li>Компьютер с Windows 10 или 11, который обычно включён (он и есть «сервер» с музыкой).</li>
<li>Папка с музыкой на этом компьютере (можно пустая — плеер сам докачает).</li>
<li>Телефон Android.</li>
<li>Для музыки вне дома — свой ВДС (сервер в интернете) с Ubuntu и доступом root. Можно настроить позже.</li>
<li>По желанию — аккаунт Яндекса (подписка не нужна): плеер узнает ваш вкус по лайкам.</li>
</ul></div>

<h2>1. Скачайте и запустите установщик</h2>
<p>Ссылка: <a href="https://vdsmusic.ru/soundflow/apk/SoundFlow-Setup.exe">vdsmusic.ru/soundflow/apk/SoundFlow-Setup.exe</a> (около 480 МБ).
Откройте скачанный файл.</p>
<p>На странице с галочками оставьте все три как есть и нажмите «Далее», потом «Установить».</p>
{img("02-tasks.png")}
<p>Windows дважды спросит разрешение — это нормально, нажмите <b>«Да»</b> оба раза:
сначала для компонентов Microsoft Visual C++, потом для qBittorrent (программа для торрентов).</p>
{img("03-uac-vc.png", 420)} {img("04-uac-qbt.png", 420)}
<p>В конце нажмите «Завершить» — SoundFlow откроется сам.</p>

<h2>2. Мастер первого запуска</h2>
<p><b>Шаг 1 — музыка.</b> Нажмите «Выбрать папку…», укажите папку с музыкой, нажмите «Дальше».
Каталог соберётся сам в фоне. Внутри появятся папки «Яндекс» и «Торренты» — туда плеер будет качать новое.</p>
{img("05-wizard-music.png")}
<p><b>Шаг 2 — Яндекс (можно пропустить).</b> Нажмите «Войти» — появится код. Откройте
<b>ya.ru/device</b> на телефоне или компьютере, войдите в свой Яндекс и введите этот код.
Страница в SoundFlow обновится сама. Пароль SoundFlow не видит.</p>
{img("07-wizard-yandex-code.png")}
<p><b>Шаг 3 — торренты.</b> Нажмите «Включить». Если SoundFlow попросит закрыть qBittorrent —
закройте его (значок у часов → «Выход») и нажмите ещё раз.</p>
{img("08-wizard-torrents.png")}
<p><b>Шаг 4 — музыка вне дома (свой ВДС).</b> Впишите адрес ВДС цифрами (например 185.10.20.30),
свой домен — если есть, иначе оставьте пустым. Нажмите «Дальше» — появится команда.</p>
{img("10-wizard-vds-command.png")}
<div class="box"><b>Как вставить команду в ВДС</b>
<ol>
<li>Нажмите «Скопировать» в SoundFlow.</li>
<li>На компьютере откройте «Пуск» → наберите <b>PowerShell</b> → откройте.</li>
<li>Наберите <code>ssh root@АДРЕС_ВДС</code> (ваш адрес), нажмите Enter, введите пароль от ВДС
(символы при вводе не видны — так и должно быть).</li>
<li>Вставьте команду <b>правой кнопкой мыши</b> и нажмите Enter.</li>
<li>Подождите 1–3 минуты, пока не появится слово <b>ГОТОВО</b>.</li>
<li>Вернитесь в SoundFlow и нажмите «Проверить».</li>
</ol>
Если на ВДС уже стоит VPN (xray, 3x-ui) — команда это видит и ничего в нём не ломает.
Если что-то не так, она сама вернёт настройки как были и напишет, в чём дело.</div>
<p><b>Шаг 5 — телефон.</b> На последней странице — код-картинка. Наведите на неё камеру телефона и
установите приложение SoundFlow (Android может спросить разрешение ставить приложения из браузера — разрешите).
Или откройте на телефоне ссылку <a href="https://vdsmusic.ru/soundflow/apk/SoundFlow.apk">vdsmusic.ru/soundflow/apk/SoundFlow.apk</a> —
там всегда последняя версия. Дальше приложение обновляется само: Профиль → «Обновить».</p>
{img("11-wizard-phone.png")}

<h2>3. Подключите телефон</h2>
<p>Телефон — в том же Wi-Fi, что и компьютер. Откройте SoundFlow на телефоне и нажмите
<b>«Найти компьютер»</b>. Если окно на компьютере уже закрылось — нажмите там «Подключить телефон ещё раз».
Вместе с адресом компьютера телефон сам получит и связь через ваш ВДС — вне дома музыка тоже будет играть.</p>
{img("13-phone-connect.png", 300)}

<h2>4. Готово — как этим пользоваться</h2>
<ul>
<li>Компьютер: SoundFlow запускается сам при входе в Windows. Не закрывайте его, если хотите слушать с телефона.</li>
<li>Новая версия программы на компьютере — в окне сверху появится лаймовая кнопка «Обновить до …».
Нажали — обновится сама, ваши настройки и музыка не трогаются.</li>
<li>Новая версия приложения на телефоне — Профиль → «Обновить».</li>
<li>Плеер сам подбирает музыку по вашим лайкам и прослушиваниям: ставьте сердечко тому, что нравится,
смахивайте обложку влево то, что не нравится.</li>
</ul>
{img("12-main-window.png")}

<h2>Если что-то не работает</h2>
<ul>
<li>Телефон не находит компьютер — проверьте, что оба в одном Wi-Fi и SoundFlow на компьютере открыт.</li>
<li>Не качаются торренты — проверьте, что qBittorrent установлен (значок у часов). Не помогло — напишите тому,
кто дал вам SoundFlow; ваши настройки лежат в файле <code>%LOCALAPPDATA%\\SoundFlow\\settings.json</code>.</li>
<li>Вне дома не играет — на компьютере должен быть интернет, SoundFlow открыт, а на ВДС выполнена команда из шага 4.</li>
</ul>
"""

HTML = f"""<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>SoundFlow — инструкция</title>
<style>
body{{margin:0;background:#fff;color:#16161a;font:16px/1.55 Inter,Segoe UI,system-ui,sans-serif}}
main{{max-width:760px;margin:0 auto;padding:24px 16px 64px}}
h1{{font-size:30px;margin:0 0 8px}} h2{{margin:36px 0 8px;font-size:22px;border-top:2px solid #B2FF00;padding-top:16px}}
.lead{{color:#55555f;font-size:17px}} img{{width:100%;height:auto;border-radius:12px;border:1px solid #e3e3e8;margin:8px 0}}
.box{{background:#f2ffd1;border-radius:12px;padding:12px 16px;margin:12px 0}}
code{{background:#f2f2f5;padding:1px 6px;border-radius:6px}} a{{color:#175e96}}
</style></head><body><main>{STEPS}</main></body></html>"""

out = HERE / "SoundFlow-инструкция.html"
out.write_text(HTML, encoding="utf-8")
print(out)
if "--pdf" in sys.argv:
    subprocess.run([sys.argv[sys.argv.index("--pdf") + 1], "-c", f"""
import asyncio
from playwright.async_api import async_playwright
async def m():
    async with async_playwright() as p:
        b = await p.chromium.launch(); pg = await b.new_page()
        await pg.goto('file://{out}'); await pg.pdf(path='{HERE / "SoundFlow-инструкция.pdf"}', format='A4', print_background=True,
            margin={{'top':'12mm','bottom':'12mm','left':'10mm','right':'10mm'}})
        await b.close()
asyncio.run(m())"""], check=True)

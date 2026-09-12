# Автообновление приложения SoundFlow — дизайн

Дата: 2026-09-12. Автор: ассистент (по задаче Alex, голосом TG 05.09-07.09
диапазон сегодняшней сессии). Статус: **одобрено Alex в чате**, спец
пишется для памяти/продолжения, отдельного файла-плана (writing-plans) не
заводим — объём умещается в один заход.

## Что просил Alex

Голосом: не скачивать/ставить новую APK руками через Telegram/USB каждый
раз — чтобы приложение само предлагало обновиться. Уточнение: «не только
дома, вообще везде» — то есть проверка должна работать из любой сети, не
только через домашний USB/Wi-Fi.

## Разобранные и отклонённые варианты

1. **Google Play (внутреннее тестирование)** — надёжнее всех технически,
   но $25 разово + смена подписи приложения (сейчас debug-keystore) → риск
   потери данных при первой установке новой подписи. Отклонено — Alex не
   готов платить и рисковать сейчас.
2. **GitHub Releases + Obtainium** — рассмотрено подробно (два внешних ИИ
   единогласно за), но Alex после проверки памяти предпочёл переиспользовать
   уже работающую у него схему (см. ниже) вместо нового стороннего
   аккаунта/приложения.
3. **Вернуть WireGuard-туннель VDS↔домашний сервер** — оба внешних ИИ и я
   единогласно ПРОТИВ: открывает весь домашний сервер ради одной функции,
   явный оверинжиниринг. Отклонено.

## Выбранный вариант — как у TaskMe

У Alex уже есть работающий, проверенный годами канал обновлений для
другого его приложения (TaskMe): статические файлы на VDS `vdsmusic.ru`
(77.239.102.216), отдаёт nginx, приложение само проверяет версию и качает.
Решено повторить тот же паттерн для SoundFlow — не заводить новых внешних
сервисов (GitHub-аккаунт, Obtainium), переиспользовать то, что уже есть и
проверено.

Важно: у TaskMe и раньше у SoundFlow (веб-версия, до переезда на
Flutter+Go, см. `SOUNDFLOW_FLUTTER_GO_MIGRATION_PLAN.md`) на этом же VDS
уже есть server-блок `vdsmusic.ru` (`/etc/nginx/sites-enabled/vdsmusic.ru`,
слушает :7443 за nginx-stream SNI-роутером). В нём — прокси на старый
веб/API SoundFlow (`tunnel_web`/`tunnel_api`, скорее всего уже не
работают — старая архитектура) и рабочие статические location-блоки
`/taskme/version`, `/taskme/apk/`. **Ничего из существующих блоков не
трогаем** — только добавляем два новых, по образцу taskme.

## Архитектура

```
SoundFlow.exe/soundflow-srv.exe (сборка) → scp → VDS /var/www/soundflow/
                                                        ├── version.json
                                                        └── apk/SoundFlow-1.0.0+NN.apk
                                                              │
                                                     nginx (vdsmusic.ru:7443)
                                                     GET /soundflow/version
                                                     GET /soundflow/apk/...
                                                              │
                                                         HTTPS (любая сеть)
                                                              │
                                                    Телефон: update_check.dart
                                                    сравнивает versionCode
                                                    → скачивает → open_filex
                                                    → системный установщик
                                                    → проверка подписи Android
                                                    → установлено (1 тап)
```

### Сервер (VDS, nginx) — новое, ничего существующего не меняем

Директории (создать): `/var/www/soundflow/version.json`,
`/var/www/soundflow/apk/`.

Новые location-блоки в `/etc/nginx/sites-enabled/vdsmusic.ru` (по образцу
уже работающих `/taskme/version` и `/taskme/apk/`, вставить рядом с ними):

```nginx
location = /soundflow/version {
    alias /var/www/soundflow/version.json;
    default_type application/json;
    add_header Cache-Control "no-store" always;
}
location /soundflow/apk/ {
    alias /var/www/soundflow/apk/;
    types { application/vnd.android.package-archive apk; }
    add_header Content-Disposition "attachment" always;
}
```

Процедура правки (как делали для TaskMe COOP-фикса — `feedback`/память):
1. `cp /etc/nginx/sites-enabled/vdsmusic.ru /etc/nginx/sites-enabled/vdsmusic.ru.bak-soundflow-update-20260912` — бэкап.
2. Вставить два блока, **не трогая ни один существующий**.
3. `nginx -t` — только если ОК:
4. `systemctl reload nginx`.
5. Проверка: `curl https://vdsmusic.ru/soundflow/version` (пока 404, пока нет
   файла — это нормально до первой публикации).

### Формат `version.json`

```json
{
  "version": "1.0.0",
  "versionCode": 36,
  "apkUrl": "https://vdsmusic.ru/soundflow/apk/SoundFlow-1.0.0+36.apk",
  "changelog": "Что нового в этой версии — коротко.",
  "releasedAt": "2026-09-12T12:00:00+03:00"
}
```

`versionCode` — то же число, что `flutter build apk --build-number=NN`
пишет в манифест (см. этап 65, фикс `6d751d8`). Сравнение строго по нему,
не по строке версии.

### Клиент (Flutter, apps/mobile) — новые файлы/правки

- **Без новых сторонних библиотек вообще.** И версия приложения
  (`versionCode`), и запуск установки — маленький нативный Kotlin-кусочек
  в `MainActivity.kt`, тем же способом, что уже сделано для
  `soundflow/device` (модель телефона, 05.09.2026, «своя пара строк на
  Kotlin, без сторонних пакетов»).
  Причины отказа от готовых пакетов (обе найдены при реализации, не
  теоретически): (1) APK-installer-пакеты — `open_filex` сам вырезает
  `REQUEST_INSTALL_PACKAGES` из манифеста (заточен под политику Google
  Play, нам мешает), у `android_package_installer` низкая версия (0.0.3)
  и требует избыточное разрешение `MANAGE_EXTERNAL_STORAGE`; (2)
  `package_info_plus` — на этой машине ломает сборку (Kotlin-инкрементальный
  кэш Gradle падает, потому что pub-cache пакета лежит на диске C:, а
  проект на E: — Windows не считает relative path между разными дисками,
  баг тулчейна конкретно на этой машине, не нашего кода; переустановка
  Flutter на тот же диск, что проект, это бы вылечило, но трогать не
  стали). И то, и другое решено своим Kotlin: `installedVersionCode()`
  (через `packageManager.getPackageInfo`) и `installApk`
  (`FileProvider.getUriForFile` + `Intent.ACTION_VIEW`) — оба в одном
  файле, полностью под контролем, без сюрпризов от чужого мёрджа
  манифеста или конфликтов путей.
- **`lib/core/update_check.dart` (новый):** `checkForUpdate()` — GET
  `https://vdsmusic.ru/soundflow/version` (через существующий `dio`),
  сравнить `versionCode` с `PackageInfo.fromPlatform()`, вернуть
  `UpdateInfo?` (null = обновлений нет). Молча проглатывать сетевые ошибки
  (нет интернета — не пугать, просто не найдено обновление) — так же, как
  ведёт себя AutoSync при недоступном сервере.
- **`lib/core/update_download.dart` (новый):** скачать APK по `apkUrl`
  через `dio` (с прогрессом — переиспользовать паттерн из
  `data/downloads_repo.dart`, там уже есть скачивание файлов с
  прогрессом) в `getTemporaryDirectory()`, вернуть путь. Затем
  `OpenFilex.open(path)` — запускает системный установщик.
- **Экран:** в `features/profile/profile_screen.dart` — новая строка «О
  программе» (текущая версия, кнопка «Проверить обновление»). При запуске
  приложения (`main.dart` или `app/shell.dart`, по аналогии с тем, как уже
  сейчас при первом кадре что-то тихо проверяется) — один тихий фоновый
  `checkForUpdate()`, если есть новее — маленький баннер/точка-индикатор
  на Профиле, не всплывающее окно поверх всего (не мешать слушать музыку).
- **AndroidManifest.xml:** добавить `<uses-permission
  android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>` и
  `FileProvider` (`<provider>` + `res/xml/file_paths.xml`) — стандартный
  Android-механизm передать скачанный файл системному установщику через
  `content://` (без него на Android 7+ install-intent не сработает).
  Authority — `ru.soundflow.soundflow.fileprovider` (по applicationId).

### Моя новая привычка при сборках

При каждой новой APK — кроме отправки Alex в Telegram, ещё:
`scp SoundFlow-1.0.0+NN.apk root@77.239.102.216:/var/www/soundflow/apk/` +
обновить `version.json` (versionCode, apkUrl, changelog, releasedAt) →
`curl https://vdsmusic.ru/soundflow/version` проверить 200 и правильный
номер. Без этого шага у приложений на телефоне просто не появится новая
версия в списке — сборка сама по себе на канал не попадает.

## Безопасность / что НЕ трогаем

- Ни один существующий location-блок vdsmusic.ru (VPN, TaskMe, Corzina
  OTA, старый SoundFlow-туннель) не редактируется.
- Подпись SoundFlow (debug keystore) не меняется — обновление ставится
  поверх старой версии, потому что подпись та же (Android иначе откажет).
- Секреты/токены в APK и так отсутствуют (сервер вводится вручную/по
  умолчанию localhost) — публикация файла в интернете не раскрывает ничего
  чувствительного (подтверждено обоими внешними ИИ).
- `REQUEST_INSTALL_PACKAGES` не даёт тихую установку без тапа — Android
  всегда спрашивает подтверждение (ограничение платформы, не наше решение).

## Не делаем сейчас (не просили)

- Автоматическую установку без тапа (Android этого не позволяет в принципе).
- Проверку подписи/хэша на стороне клиента сверх того, что уже даёт
  системная проверка Android при установке (можно добавить sha256-сверку
  позже, если появится причина не доверять каналу).
- Откат на предыдущую версию из приложения — только вперёд, как и раньше
  (ручная переустановка APK при необходимости).

## Тестирование

- `dart analyze` чисто после правок (как для всех прошлых фич).
- Ручная проверка на реальном телефоне Alex (per house rule — не
  заявлять «готово» без этого): версия текущая → должна показать «нет
  обновлений»; временно завысить `versionCode` в `version.json` на VDS →
  должна показать «доступно обновление» → скачать → установить → версия
  реально сменилась.
- Проверить работу НЕ дома (мобильный интернет/чужой Wi-Fi) — это и есть
  ключевое требование «вообще везде».

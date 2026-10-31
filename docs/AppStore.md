# RedTask — подготовка к App Store

## Уже сделано в проекте
- Bundle ID `ru.toxblh.RedTask`, Team `MUMWZ78YDU`, автоматическая подпись, iOS 18+, iPhone и iPad.
- `PrivacyInfo.xcprivacy`: трекинга нет, сбор данных — нет, Required Reason API — только UserDefaults (CA92.1).
- `ITSAppUsesNonExemptEncryption = NO` (только HTTPS системного URLSession) — вопрос об экспорте шифрования
  в App Store Connect не задаётся.
- Ключ API — в Keychain (`AfterFirstUnlockThisDeviceOnly`), «Выйти» стирает ключ и кэши.
- Разрешений на доступ нет: фото — системный PhotosPicker, файлы — fileImporter, уведомления — тихие (provisional).
- Фоновая проверка: `UIBackgroundModes = fetch`, `BGTaskSchedulerPermittedIdentifiers = ru.toxblh.RedTask.poll`.
- Локализация en + ru (String Catalog), иконка-заготовка (светлая/тёмная/tinted) в `Assets.xcassets/AppIcon`.
- Associated Domains `applinks:my.basealt.space` — заготовка (см. ниже).

## Что нужно от владельца
1. **Distribution-сертификат** (Apple Distribution) в связке ключей Мака — Xcode → Settings → Accounts →
   Manage Certificates → «+» → Apple Distribution. С автоматической подписью профиль App Store создастся сам.
2. **App ID с возможностью Associated Domains** — при первой подписи на устройство/архиве Xcode включит её сам
   (`-allowProvisioningUpdates`); если Associated Domains пока не нужны — убрать ключ из `RedTask.entitlements`.
3. **Запись в App Store Connect**: My Apps → «+» → New App: платформа iOS, имя «RedTask» (если занято —
   «RedTask for Redmine»), основной язык, Bundle ID `ru.toxblh.RedTask`, SKU (любой, например `redtask`).
4. **URL политики конфиденциальности** (обязателен). Суть текста: приложение не собирает данных; адрес сервера,
   API-ключ и кэш задач хранятся только на устройстве; запросы идут только на указанный пользователем сервер Redmine.
5. **App Privacy** в App Store Connect: «Data Not Collected».
6. **Демо-доступ для ревью** (Guideline 2.1) — сервер не нужен: на экране входа есть кнопка «Try Demo» /
   «Попробовать без сервера». Демо работает офлайн на встроенных выдуманных данных (4 проекта, 26 задач,
   люди, комментарии, время, вложения, колокольчик), действия — в памяти, перезапуск сбрасывает демо,
   выход — «Sign Out» в настройках (там же плашка «Demo»). Сеть в демо не используется
   (транспорт `DemoServer`, URLProtocol). В App Review Information:
   - Sign-in required: **No** (или Yes с пояснением ниже — поля логина можно оставить пустыми);
   - Notes:
     > RedTask is a client for self-hosted Redmine servers, so it normally needs the user's own server.
     > To review the app without a server, tap **Try Demo** at the bottom of the sign-in screen. The demo
     > runs fully offline on built-in sample data; all actions (comments, status, assignee, time logging,
     > favorites, new issues) work in memory and reset on relaunch. To leave the demo, open Settings
     > (gear icon) → Sign Out.
7. **Скриншоты**: iPhone 6.9" (1320×2868 или 1290×2796) — обязательно; iPad 13" (2064×2752) — раз приложение
   универсальное. Сняты в демо (`-RTDemo YES`, светлая тема, ru и en) в `docs/screenshots/appstore/`:
   список «Мои», задача с Textile, задача с комментариями, редактор комментария, колокольчик, карточка человека.
   Отладочные аргументы — только в Debug-сборке; снимки с ними чистые (без отладочных плашек).
8. **Описание, ключевые слова, URL поддержки, возрастной рейтинг** (4+, без пользовательского контента от
   приложения — контент приходит с сервера пользователя), категория Productivity.
9. **Иконка**: готова — стопка карточек задач с галочкой (светлая, тёмная, tinted), 1024×1024 RGB без альфы; исходник `tools/app-icon.py` (`python3 tools/app-icon.py <каталог>`).
10. **Сборка и загрузка**: `tools/archive.sh` (архив и .ipa на Маке; `UPLOAD=1` — сразу в App Store Connect), либо Product → Archive (схема RedTask, Any iOS Device) → Distribute App → App Store Connect,
    либо `xcodebuild archive` + `xcodebuild -exportArchive` с `method = app-store-connect`.
    Поднимать `CURRENT_PROJECT_VERSION` в `project.yml` на каждую загрузку.

## Universal links (когда сервер будет готов)
Положить на сервер `https://my.basealt.space/.well-known/apple-app-site-association` (JSON, без расширения,
`Content-Type: application/json`, без редиректов):

```json
{
  "applinks": {
    "details": [
      { "appIDs": ["MUMWZ78YDU.ru.toxblh.RedTask"], "components": [ { "/": "/issues/*" } ] }
    ]
  }
}
```
Приложение уже обрабатывает `https://my.basealt.space/issues/123` и `…#note-N` (переход к задаче/комментарию).
Внимание: WAF «Security check» не должен перехватывать запрос Apple CDN к этому файлу.

## Известные ограничения, которые стоит упомянуть в описании/ревью
- Фоновая проверка уведомлений работает по расписанию iOS (обычно не чаще раза в 15 минут, реже при редком
  использовании) — push с сервера Redmine не поддерживается без серверного плагина.
- Наблюдение за задачей через REST на части серверов разрешено только администратору — тогда открывается веб-версия.

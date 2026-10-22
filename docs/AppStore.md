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
6. **Демо-доступ для ревью** (Guideline 2.1): тестовый Redmine-сервер и API-ключ/логин-пароль в App Review
   Information. Без него ревью отклонит приложение, работающее только с корпоративным сервером. Желательно
   тестовая учётка на публичном сервере без WAF-капчи.
7. **Скриншоты**: iPhone 6.9" (1320×2868 или 1290×2796) — обязательно; iPad 13" (2064×2752) — раз приложение
   универсальное. Снимать: список «Мои», экран задачи с комментариями, редактор комментария, колокольчик,
   iPad со сайдбаром. `xcrun simctl io <udid> screenshot` на iPhone 17 Pro Max / iPad Pro 13".
8. **Описание, ключевые слова, URL поддержки, возрастной рейтинг** (4+, без пользовательского контента от
   приложения — контент приходит с сервера пользователя), категория Productivity.
9. **Иконка**: заменить заготовку финальной (1024×1024, без альфы) — лучше через Icon Composer (`.icon`).
10. **Сборка и загрузка**: Product → Archive (схема RedTask, Any iOS Device) → Distribute App → App Store Connect,
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

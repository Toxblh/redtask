# RedTask

Нативный iOS/iPadOS-клиент Redmine (SwiftUI, iOS 18+). Паритет с Android-приложением Redmine Expressive.

## Сборка

Проект генерируется XcodeGen из `project.yml` (`.xcodeproj` в git не хранится):

```sh
xcodegen generate
xcodebuild -project RedTask.xcodeproj -scheme RedTask -destination 'generic/platform=iOS Simulator' -derivedDataPath build build
```

С Linux-машины: `tools/build.sh build` (rsync на Мак + xcodebuild), `tools/sim.sh <udid> <имя-скриншота> [аргументы]`.

Отладочный вход без UI (только Debug): `xcrun simctl launch <udid> ru.toxblh.RedTask -RTKey <ключ> [-RTServer URL] [-RTIssue id] [-RTTab mine|watched|favorites|projects|search] [-RTSheet bell|settings|new]`.

Правила HIG, применённые в проекте: `docs/HIG-notes.md`.

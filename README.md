# DiabTimer

iOS-App für Wechsel-Timer auf Basis der Careportal-Daten eines Nightscout-Servers: Wie lange
sind Kanüle, Schlauch, Insulin, Sensor und Pumpenbatterie schon in Gebrauch, und wann ist der
nächste Wechsel fällig?

> **Kein Medizinprodukt.** DiabTimer berechnet keine Dosen und gibt keine BZ-Alarme aus.

- Liest und schreibt Wechsel über **Nightscout API v3** (ab Nightscout 15).
- Der **Schlauch** hat in Nightscout keinen Ereignistyp und wird über **iCloud** abgeglichen.
- **Erinnerungen** als lokale Mitteilungen: gebündelt, mit Schlummern, Ruhezeiten und täglicher
  Erinnerung bei Überfälligkeit.
- **Widgets** für Home- und Sperrbildschirm, mit „Gewechselt“-Button (zwei Tipps).
- Verteilung über **TestFlight**, gebaut ausschließlich über **GitHub Actions**.

Den vollständigen Plan mit allen Entscheidungen enthält [PLAN.md](PLAN.md).

## Aufbau

| Pfad | Inhalt |
|---|---|
| `Packages/DiabTimerKit` | Swift-Paket mit der Logik: `TimerCore` (Timer, Schwellen, Erinnerungsplan), `NightscoutKit` (API-v3-Client), `Persistence` (Zustand, Warteschlange, Abgleich, iCloud). Läuft und testet auch unter Linux. |
| `Shared` | Code für App und Widget: `ChangeService`, Mitteilungen, App Intents, Keychain |
| `App` | SwiftUI-App |
| `Widget` | Widget-Extension |
| `UITests` | UI-Tests |
| `project.yml` | XcodeGen-Projektbeschreibung, das Xcode-Projekt wird daraus erzeugt |
| `Config` | xcconfig-Dateien (Bundle-IDs aus der Team-ID, Versionsnummer) |
| `fastlane`, `.github/workflows` | Signierung und TestFlight-Upload, Aufbau wie im Loop-Fork |

## Nightscout vorbereiten

In Nightscout unter **Admin-Werkzeuge**:

1. Rolle `diabtimer` anlegen mit den Rechten

   ```
   api:status:read
   api:treatments:read
   api:treatments:create
   api:treatments:update
   api:treatments:delete
   ```

2. Ein Subject mit dieser Rolle anlegen. Dessen Zugriffstoken wird in der App eingetragen.

Mindestvariante: die Standardrollen `readable` und `careportal`. Dann lassen sich gesendete
Einträge nicht korrigieren oder löschen.

## Build über GitHub Actions

Die Secrets `TEAMID`, `FASTLANE_KEY_ID`, `FASTLANE_ISSUER_ID`, `FASTLANE_KEY`, `GH_PAT` und
`MATCH_PASSWORD` kommen aus den Organisations-Secrets. Signiert wird mit dem bestehenden Repo
`Match-Secrets` (fastlane match).

Einmalige Einrichtung:

1. Workflow **1. Validate Secrets** ausführen.
2. Workflow **2. Add Identifiers** ausführen. Legt `com.<TEAMID>.DiabTimer` und
   `com.<TEAMID>.DiabTimer.DiabTimerWidgetExtension` an.
3. Im [Apple-Developer-Portal](https://developer.apple.com/account/resources/identifiers/list)
   die App Group `group.com.<TEAMID>.DiabTimerGroup` anlegen und beiden Bundle-IDs zuordnen.
4. In [App Store Connect](https://appstoreconnect.apple.com) die App „DiabTimer“ mit der
   Bundle-ID `com.<TEAMID>.DiabTimer` anlegen und eine interne Testgruppe einrichten.
5. Workflow **3. Create Certificates** ausführen.
6. Workflow **4. Build DiabTimer** ausführen.

Danach baut **4. Build DiabTimer Auto** jeden Sonntag, wenn es neue Commits auf `main` gibt,
und am 2. Sonntag im Monat in jedem Fall. Abschalten über die Repo-Variablen
`BUILD_ON_NEW_COMMITS=false` bzw. `SCHEDULED_BUILD=false`.

Das gemeinsame Verteilungszertifikat wird hier nie widerrufen. Läuft es ab, wird es zentral im
Loop-Fork erneuert, danach hier Workflow 3 erneut ausführen.

## Lokal entwickeln (optional)

```sh
brew install xcodegen
echo "DEVELOPMENT_TEAM = <TEAMID>" > Config/DiabTimerConfig.local.xcconfig
xcodegen generate
open DiabTimer.xcodeproj
```

Nur die Logik testen, auch unter Linux:

```sh
swift test --package-path Packages/DiabTimerKit
```

## Lizenz

GPL-3.0, siehe [LICENSE](LICENSE).

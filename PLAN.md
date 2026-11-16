# Plan: Wechsel-Timer für Nightscout (iOS)

Eine iOS-App, die anhand der Careportal-Daten eines Nightscout-Servers anzeigt, wie lange
Kanüle, Sensor, Insulin und Pumpenbatterie schon in Gebrauch sind. Sie trägt neue Wechsel in
Nightscout ein und erinnert rechtzeitig per Widget, Benachrichtigung und Alarm. Zusätzlich gibt
es einen Timer für den Schlauch. Für ihn kennt Nightscout keinen Ereignistyp, deshalb wird er
nicht über Nightscout, sondern über **iCloud** zwischen den eigenen Geräten synchronisiert.

> **Hinweis:** Die App ist kein Medizinprodukt. Sie berechnet keine Dosen und gibt keine
> BZ-Alarme aus, sie verwaltet nur Wechsel-Erinnerungen.

## Eckdaten

| | |
|---|---|
| Plattform | iPhone, **Mindestversion iOS 26** (iPhone 11 und neuer) |
| Nightscout | **genau ein Server** |
| Schlauch-Timer | **iCloud** (private CloudKit-Datenbank), nie Nightscout |
| Verteilung | **TestFlight, nur interne Tester** |
| CI / Upload | **GitHub Actions mit fastlane** |
| Sprache / UI | Swift 6, SwiftUI im Liquid-Glass-Design |

---

## 1. Umfang

### Im Umfang (MVP)
| Bereich | Inhalt |
|---|---|
| **Timer** | Kanüle (CAGE), Sensor (SAGE), Insulin (IAGE), Pumpenbatterie (BAGE) aus Nightscout, dazu **Schlauch (über iCloud)**. Jeder mit Ampelstatus (ok / Info / Warnung / dringend) und Zeit bis zum nächsten Wechsel |
| **Eintragen** | Ein Tipp auf „Kanüle gewechselt“ usw., optional mit abweichendem Zeitpunkt und Notiz. Beim Kanülenwechsel ist „Schlauch auch gewechselt“ standardmäßig an. Eigene Einträge lassen sich korrigieren oder löschen |
| **Verlauf** | Liste der letzten Wechsel je Typ, durchschnittliche Tragedauer |
| **Benachrichtigungen** | Lokal geplante Erinnerungen für Info und Warnung, mit Aktionen direkt aus der Benachrichtigung |
| **Alarme (AlarmKit)** | Stufe „dringend“ als echter Alarm, der auch im Stummmodus klingelt |
| **Countdown (Live Activity)** | Countdown im Dynamic Island und auf dem Sperrbildschirm, 2 Stunden bevor ein Wechsel dringend wird |
| **Widgets** | Home- und Lock-Screen-Widgets, auch in **CarPlay**, mit interaktivem Button „Gewechselt“ |
| **Kontrollzentrum** | Steuerelement „Gewechselt“ pro Timer |
| **Siri / Kurzbefehle / Spotlight** | App Intents mit **interaktiver Bestätigung** („Kanüle jetzt als gewechselt eintragen?“) |

### Bewusst nicht im Umfang
- BZ-Werte, Bolus, KH, Basalraten. Dafür gibt es xDrip4iOS, Loop, Trio usw.
- Mehrere Nightscout-Server
- Upload des Schlauch-Timers nach Nightscout
- Synchronisierung der Nightscout-Daten über iCloud (Nightscout ist dafür die Quelle)
- Eigenes Push-Backend
- Android, App Store, externe TestFlight-Tester

### Später denkbar
- Apple-Watch-Komplikation
- Vorratsverwaltung („noch 3 Sensoren übrig“)

---

## 2. Timer

| Timer | Quelle | Ereignis | Standard-Schwellen (Info / Warnung / dringend) |
|---|---|---|---|
| Kanüle (CAGE) | Nightscout | `Site Change` | 44 h / 48 h / 72 h |
| Sensor (SAGE) | Nightscout | jüngstes von `Sensor Start` und `Sensor Change` | 144 h / 164 h / 166 h |
| Insulin (IAGE) | Nightscout | `Insulin Change` | 44 h / 48 h / 72 h |
| Batterie (BAGE) | Nightscout | `Pump Battery Change` | 312 h / 336 h / 360 h |
| **Schlauch** | **iCloud** | Ereignis `tubingChange` (nur in der App) | **120 h / 144 h / 168 h** (5 / 6 / 7 Tage) |

### Gemeinsame Regeln
- Die Schwellen der Nightscout-Timer werden beim Einrichten aus `/api/v1/status.json`
  übernommen (`settings.extendedSettings.cage.warn` usw.), sofern der Server sie liefert. Sonst
  gelten die Standardwerte oben. In der App lassen sie sich pro Timer überschreiben.
- Einzelne Timer lassen sich ausblenden (z. B. Batterie bei Patch-Pumpen, Schlauch bei
  schlauchlosen Pumpen).
- Das Alter wird immer lokal aus dem Zeitstempel berechnet (`jetzt − letzterWechsel`). Für die
  Anzeige sind keine Netzwerkzugriffe nötig.
- Zeit wird intern in UTC gespeichert. So rechnen die Timer auch nach Zeitzonenwechseln und der
  Sommer-/Winterzeit-Umstellung richtig.
- Die Timer-Logik ist eine reine Funktion `(letzterWechsel, schwellen, jetzt) -> TimerStatus`.
  App, Widgets, Benachrichtigungen, Alarme und Live Activity nutzen sie gemeinsam. Sie lässt sich
  vollständig per Unit-Test prüfen.

### Schlauch-Timer (über iCloud)
- Nightscout hat keinen Ereignistyp für den Schlauchwechsel. Die Wechsel werden deshalb in der
  **privaten CloudKit-Datenbank** des eigenen iCloud-Kontos gespeichert und zwischen den Geräten
  mit derselben Apple-ID synchronisiert. Nach Nightscout gehen sie nie.
- Gespeichert wird jeder Wechsel als eigener Datensatz mit fester UUID (nur hinzufügen,
  korrigieren, löschen). Echte Konflikte sind damit selten. Wird derselbe Datensatz auf zwei
  Geräten geändert, gewinnt die zuletzt gespeicherte Änderung.
- **Ohne iCloud** (abgemeldet oder iCloud für die App aus) funktioniert der Timer weiter, nur
  ohne Synchronisierung. Die Einstellungen zeigen den iCloud-Status an. Sobald iCloud wieder
  verfügbar ist, werden die Daten nachgeliefert.
- Nach einer Neuinstallation oder auf einem neuen Gerät kommen die Daten aus iCloud zurück. Nur
  wenn dort nichts liegt, fragt die Einrichtung nach dem letzten Schlauchwechsel.
- **„Schlauch auch gewechselt“:** Beim Eintragen von „Kanüle gewechselt“ (in der App, im Widget,
  im Kontrollzentrum, per Siri und aus Benachrichtigungen) ist dieser Schalter **standardmäßig
  an**. Er lässt sich pro Eintrag ausschalten und in den Einstellungen dauerhaft auf „aus“
  stellen.
- Alles andere funktioniert wie bei den Nightscout-Timern: Widget, Benachrichtigung, Alarm,
  Countdown, Kontrollzentrum, Siri.

---

## 3. Nightscout-Anbindung

### API
- **Bevorzugt API v3** (Nightscout ab Version 15), **v1 als Fallback**. Welche Version der
  Server kann, wird beim Einrichten festgestellt.
- **Letzten Wechsel lesen:**
  - v3: `GET /api/v3/treatments?eventType$eq=Site%20Change&sort$desc=date&limit=1`
  - v1: `GET /api/v1/treatments.json?find[eventType]=Site%20Change&count=1`
- **Abgleich (v3):** `GET /api/v3/treatments/history/{lastModified}` liefert nur geänderte
  Einträge. Das ist ideal für Hintergrund-Abrufe und erkennt auch Wechsel, die AAPS, Loop
  oder die Nightscout-Weboberfläche eingetragen haben.
- **Schreiben:** `POST /api/v3/treatments` bzw. `POST /api/v1/treatments` mit
  ```json
  {
    "eventType": "Site Change",
    "created_at": "2026-11-16T08:30:00.000Z",
    "date": 1794817800000,
    "utcOffset": 60,
    "enteredBy": "Wechsel-Timer (iOS)",
    "identifier": "<UUID von der App erzeugt>",
    "notes": "optional"
  }
  ```
  Die App erzeugt die `identifier` selbst. Wird ein Eintrag nach einem Netzwerkfehler erneut
  gesendet, entsteht so kein Duplikat.
- **Löschen/Korrigieren:** Nur Einträge, deren `enteredBy` von dieser App stammt.

### Anmeldung
- **Empfohlen:** Nightscout-Zugriffstoken mit der Rolle `careportal`. Anzulegen in der
  Nightscout-Weboberfläche unter *Admin-Werkzeuge → Subjects*. In v3 wird es über
  `/api/v2/authorization/request/<token>` gegen ein JWT getauscht, das sich bei Ablauf
  automatisch erneuert.
- **Fallback:** `API_SECRET` (als SHA1-Hash im Header `api-secret`) mit einem deutlichen
  Hinweis, dass dieses Geheimnis vollen Schreibzugriff gibt.
- Token, Secret und JWT werden im **Keychain** gespeichert, mit einer Access Group, damit
  Widget- und Intent-Code sie mitnutzen können. Sie werden nicht über die iCloud-Schlüsselbund-
  Synchronisierung geteilt, auf jedem Gerät wird der Server einmal eingerichtet.
- Es gibt genau eine Server-Konfiguration. Ein Serverwechsel in den Einstellungen löscht den
  Nightscout-Cache, die Schlauch-Daten in iCloud bleiben erhalten.

---

## 4. Architektur

```
┌──────────────────────────── App ─────────────────────────────┐
│  SwiftUI-Ansichten (Übersicht, Verlauf, Einstellungen)       │
│                            ↕                                 │
│  ChangeStore (Observable) ── Offline-Queue (nur Nightscout)  │
│        ↕                   ↕                                 │
│  NightscoutClient       SwiftData (App-Group-Container)      │
│                         ├─ Store „nightscout“ (Cache, lokal) │
│                         └─ Store „tubing“ (CloudKit-Sync) ───┼──► iCloud (privat)
└───────┬───────────────────┬──────────────────────────────────┘
        │                   ├──► Widget-Extension (Widgets, Controls, Live Activity)
   Nightscout               ├──► ReminderScheduler
                            │      ├─ UNUserNotificationCenter (Info, Warnung)
                            │      └─ AlarmKit (dringend, Countdown)
                            └──► App Intents (Siri, Kurzbefehle, Spotlight, Snippets)
```

### Module (lokale Swift Packages)
| Modul | Aufgabe | Abhängigkeiten |
|---|---|---|
| `NightscoutKit` | API-Client (v1/v3), Auth, DTOs, Fähigkeitserkennung | Foundation |
| `TimerCore` | Timer-Typen, Schwellen, Statusberechnung, Erinnerungsplan | Foundation |
| `Persistence` | SwiftData-Modelle, zwei Stores (lokal und CloudKit), Offline-Queue, App-Group-Zugriff | TimerCore |
| `ChangeIntents` | `LogChangeIntent`, `UndoChangeIntent`, `RefreshIntent`, Snippet-Ansichten | alle |

### Datenmodell (Kern)
```swift
enum TimerKind: String, Codable { case cannula, sensor, insulin, battery, tubing }

enum TimerSource { case nightscout(eventTypes: [String]), iCloud }

// Store „nightscout“: nur lokal, wird aus Nightscout neu aufgebaut
@Model final class NightscoutChange {
    @Attribute(.unique) var identifier: String
    var kind: TimerKind
    var date: Date            // UTC
    var note: String?
    var enteredByThisApp: Bool
    var syncState: SyncState  // .synced, .pending
}

// Store „tubing“: über CloudKit synchronisiert
@Model final class TubingChange {
    var id: UUID = UUID()     // CloudKit: keine .unique-Attribute, Standardwerte nötig
    var date: Date = Date.now // UTC
    var note: String?
    var deviceName: String?
}
```
- Die Trennung in zwei Stores (`ModelConfiguration` mit `cloudKitDatabase: .private(...)` bzw.
  `.none`) hält die CloudKit-Regeln vom Nightscout-Cache fern. Für CloudKit gilt: keine
  `.unique`-Attribute, alle Eigenschaften optional oder mit Standardwert, Beziehungen optional.
- `TubingChange` wird nie in die Offline-Queue aufgenommen.

### Targets
- **App** (iOS 26)
- **Widget-Extension**: Widgets, Kontrollzentrum-Steuerelemente, Live Activity für AlarmKit
- **Unit-Tests** (Swift Testing) und **UI-Tests** (XCTest)

### Datenabgleich
1. **App im Vordergrund:** Nightscout-Abgleich beim Start, bei Pull-to-Refresh und nach jedem
   Eintrag. iCloud synchronisiert der Store selbst.
2. **Hintergrund:** `BGAppRefreshTask` (iOS bestimmt den Zeitpunkt) für Nightscout. Für iCloud
   kommen stille CloudKit-Pushes, wenn ein anderes Gerät einen Schlauchwechsel einträgt.
3. **Offline:** Eigene Einträge landen sofort in der lokalen DB und, nur bei Nightscout-Timern,
   in der Queue. Schlauch-Einträge liefert CloudKit von selbst nach. Timer, Widgets und
   Erinnerungen werden direkt aktualisiert.
4. Nach jeder Änderung aus Nightscout, iCloud oder einem eigenen Eintrag: Widget-Timelines und
   Controls neu laden und alle Erinnerungen neu planen.

### Zugriff aus der Widget-Extension
Die Widget-Extension liest die Daten, schreibt aber nicht selbst in den CloudKit-Store. Ein
Eintrag per Widget-Button oder Control wird über ein App Intent an die App übergeben bzw. in die
gemeinsame Datenbank geschrieben, ohne dass zwei Prozesse gleichzeitig mit CloudKit
synchronisieren. Wie das genau am robustesten geht, klärt ein Spike in Phase 0 (siehe Risiken).
Rückfallebene: Die App schreibt nach jeder Änderung einen kleinen Snapshot (JSON) in die App
Group, den die Widgets lesen.

---

## 5. Erinnerungen: Benachrichtigungen, Alarme, Countdown

Alle Erinnerungen werden **lokal geplant**, ein eigener Push-Server ist nicht nötig. Nightscout
kann Apps keine Push-Nachrichten senden, aber die Wechselzeitpunkte stehen vorher fest. Nach
jedem Abgleich oder Eintrag berechnet `TimerCore` einen Erinnerungsplan, und der
`ReminderScheduler` ersetzt damit alle bisherigen Erinnerungen. Das ist idempotent und testbar.

Jedes Gerät plant seine Erinnerungen selbst. Wird der Schlauch auf einem anderen Gerät als
gewechselt eingetragen, plant dieses Gerät nach dem iCloud-Abgleich neu.

### Stufen
| Stufe | Mechanismus | Verhalten |
|---|---|---|
| Info | Benachrichtigung (`active`) | Banner, respektiert Ruhezeiten |
| Warnung | Benachrichtigung (`timeSensitive`) | Banner, respektiert Ruhezeiten |
| Countdown | AlarmKit-Countdown als Live Activity | erscheint **2 Stunden** vor „dringend“ (einstellbar) im Dynamic Island und auf dem Sperrbildschirm |
| Dringend | **AlarmKit-Alarm** | klingelt auch im Stummmodus und bei Fokus, Vollbild-Alarm |

Jede Stufe lässt sich pro Timer abschalten. Wer keinen AlarmKit-Zugriff erlaubt, bekommt für
„dringend“ stattdessen eine `timeSensitive`-Benachrichtigung.

### Aktionen
- **Benachrichtigungen:** „Jetzt gewechselt“ (trägt ohne App-Start ein), „In 1 Std. erinnern“,
  „Morgen früh erinnern“.
- **Alarm:** Hauptbutton „Jetzt gewechselt“ (über `LiveActivityIntent`), zweiter Button
  „Später“ (Schlummern, einstellbare Dauer).
- **Live Activity:** Button „Gewechselt“ direkt im Countdown.
- Bei Kanüle gilt überall der Standard „Schlauch auch gewechselt“ (an).

### Ruhezeiten
Info- und Warnungs-Benachrichtigungen, die nachts fällig würden, werden auf eine einstellbare
Uhrzeit verschoben. Der Alarm „dringend“ ist bewusst davon ausgenommen. Optional lässt sich auch
der Alarm in der Ruhezeit auf deren Ende verschieben.

### AlarmKit-Details
- `NSAlarmKitUsageDescription` in der Info.plist, Erlaubnis über
  `AlarmManager.shared.requestAuthorization()` in der Einrichtung, mit Erklärung warum.
- Alarm mit festem Zeitpunkt (`Alarm.Schedule.fixed`) zur Schwelle „dringend“ und
  Countdown-Darstellung über `AlarmPresentation` und `AlarmAttributes`. Die Ansichten für
  Dynamic Island und Sperrbildschirm liegen in der Widget-Extension.
- Je Timer höchstens ein Alarm. Bei jeder Neuplanung werden die alten über ihre ID abgesagt.
- **Technischer Spike zu Beginn von Phase 4:** prüfen, wie der Countdown vor einem
  terminierten Alarm genau gestartet werden kann (Vor-Countdown von AlarmKit oder eigene Live
  Activity) und ob die Systemgrenzen für Live Activities den Vorlauf von 2 Stunden zulassen.

---

## 6. Widgets und Kontrollzentrum

| Ort | Inhalt |
|---|---|
| Lock Screen (rund/rechteckig) | Ein Timer als Ring mit Restzeit bzw. kompakte Liste |
| Home Screen klein | Ein frei wählbarer Timer, Ampelfarbe, Alter, Button „Gewechselt“ |
| Home Screen mittel | Alle aktiven Timer nebeneinander |
| CarPlay | Kompakte Timer-Liste (nur Anzeige, keine Buttons während der Fahrt) |
| Kontrollzentrum | Steuerelement pro Timer: Symbol und Alter, Tippen trägt den Wechsel ein (mit Bestätigung) |

- Das Alter wird mit `Text(date, style: .relative)` angezeigt und läuft ohne Timeline-Updates
  weiter. Timeline-Einträge gibt es nur an den Schwellenzeitpunkten, wenn die Farbe wechselt.
- Konfiguration per `AppIntentConfiguration` (welcher Timer, auch Schlauch).
- Darstellung in den Liquid-Glass-Varianten (getönt, klar) mit `widgetAccentedRenderingMode`.
- Der Button „Gewechselt“ löst `LogChangeIntent` aus. Bei versehentlichem Tippen kann der
  Eintrag in der App oder per Benachrichtigung „Rückgängig“ zurückgenommen werden.

---

## 7. Siri, Kurzbefehle, Spotlight

- `LogChangeIntent(kind:, date:, note:, alsoTubing:)` mit **interaktivem Snippet**: zeigt das
  aktuelle Alter und fragt „Jetzt als gewechselt eintragen?“ mit den Buttons „Eintragen“ und
  „Abbrechen“.
- Beim Kanülenwechsel zeigt das Snippet zusätzlich den Schalter „Schlauch auch gewechselt“
  (standardmäßig an).
- `GetTimerStatusIntent(kind:)` gibt Alter und Status zurück, z. B. für eigene Automationen in
  Kurzbefehlen.
- App Shortcuts mit deutschen und englischen Phrasen („Kanüle gewechselt in Wechsel-Timer“).

---

## 8. Bedienung

- **Übersicht:** Je Timer eine Karte mit Ampelring, Alter und „fällig in …“. Der Schlauch-Timer
  trägt ein kleines iCloud-Symbol, durchgestrichen wenn iCloud nicht verfügbar ist. Langes
  Drücken öffnet „Gewechselt um …“ (abweichende Uhrzeit) und Notiz.
- **Verlauf:** Liste je Typ, Tragedauer pro Wechsel, Durchschnitt der letzten 10. Beim
  Schlauch zusätzlich, auf welchem Gerät eingetragen wurde.
- **Einstellungen:** Server und Token, Verbindungstest, iCloud-Status, Timer an/aus, Schwellen,
  Erinnerungsstufen pro Timer, Countdown-Vorlauf (Standard 2 h), Ruhezeiten,
  „Schlauch auch gewechselt“ (Standard an).
- **Einrichtung:** URL → Token → Test → Schwellen übernehmen → letzter Schlauchwechsel (nur
  wenn in iCloud nichts liegt) → Benachrichtigungen erlauben → Alarme erlauben.
- Liquid-Glass-Design mit Systemkomponenten, Lokalisierung Deutsch und Englisch
  (String Catalog), Dynamic Type, VoiceOver und Farbenblindheit (Ampel zusätzlich mit Symbol).

---

## 9. Verteilung über TestFlight (nur intern)

- Voraussetzung: Mitgliedschaft im **Apple Developer Program**, App-Eintrag in App Store Connect
  (wird nicht veröffentlicht).
- **Nur interne Tester:** Personen, die als Benutzer im App-Store-Connect-Team angelegt sind
  (bis zu 100). Builds stehen ohne Beta-App-Prüfung durch Apple zur Verfügung.
- TestFlight-Builds laufen nach **90 Tagen** ab. Die CI lädt deshalb regelmäßig neue Builds hoch
  (siehe unten).
- **CloudKit:** TestFlight-Builds nutzen die **Produktionsumgebung** von CloudKit. Das
  CloudKit-Schema muss vor dem ersten TestFlight-Build und nach jeder Modelländerung im CloudKit
  Dashboard nach Production übertragen werden. Schemaänderungen nur hinzufügend, nie Felder
  löschen oder umbenennen.
- **Capabilities:** App Groups, Keychain Sharing, iCloud (CloudKit, Container
  `iCloud.<bundle-id>`), Push Notifications und Background Modes (Background fetch, Remote
  notifications). Push wird nur für die stillen CloudKit-Benachrichtigungen gebraucht, es gibt
  keinen eigenen Push-Server. AlarmKit braucht nur den Info.plist-Eintrag.
- Testhinweise in TestFlight enthalten den Hinweis „kein Medizinprodukt“ und eine Anleitung zum
  Anlegen des `careportal`-Tokens.

### CI: GitHub Actions mit fastlane und dem bestehenden `Match-Secrets`-Repo

Für die Signierung wird das **bestehende private Repo `feebleeDIYorg/Match-Secrets`**
verwendet. Dort liegen bereits das Verteilungszertifikat und die App-Store-Profile für Loop,
Trio, xDrip4iOS, LoopFollow und InsulinOCR (fastlane match 2.241.1, Typ `appstore`). Die neue
App bekommt dort nur **zusätzliche Profile**, das vorhandene Zertifikat wird mitbenutzt.

Der Aufbau folgt dem Ablauf, den die Browser-Builds von Loop und Trio mit demselben Repo nutzen:

| Workflow | Auslöser | Aufgabe |
|---|---|---|
| `ci.yml` | jeder Push und Pull Request | Build, Unit-Tests, UI-Tests im Simulator. Braucht keine Secrets |
| `1-validate-secrets.yml` | manuell | Prüft, ob alle Secrets gesetzt sind und der API-Schlüssel sowie der Zugriff auf `Match-Secrets` funktionieren |
| `2-add-identifiers.yml` | manuell, einmalig und nach Capability-Änderungen | Legt die Bundle-IDs mit ihren Capabilities im Developer-Portal an (App Groups, iCloud/CloudKit, Push) |
| `3-create-certificates.yml` | manuell, einmalig und nach Capability-Änderungen | `match appstore` mit `readonly: false` für **nur die Bundle-IDs dieser App**: erzeugt die Profile und legt sie verschlüsselt in `Match-Secrets` ab |
| `4-testflight.yml` | Tag `v*`, manuell und **monatlich per Zeitplan** | `match` mit `readonly: true`, Build-Nummer erhöhen, `gym` (Archiv), `pilot` (Upload an die interne Gruppe) |

#### Secrets
Dieselben Namen wie bei Loop, Trio und LoopFollow. Sind sie in `feebleeDIYorg` bereits als
**Organisations-Secrets** angelegt, bekommt dieses Repo sie automatisch, sobald es freigegeben
ist. Sonst werden sie in diesem Repo mit denselben Werten angelegt.

| Secret | Inhalt |
|---|---|
| `TEAMID` | Apple-Team-ID (wird nicht ins öffentliche Repo geschrieben, Bundle-IDs werden im Workflow daraus zusammengesetzt, wo nötig) |
| `FASTLANE_KEY_ID` | ID des App-Store-Connect-API-Schlüssels |
| `FASTLANE_ISSUER_ID` | Issuer-ID des API-Schlüssels |
| `FASTLANE_KEY` | Inhalt der `.p8`-Datei |
| `GH_PAT` | GitHub-Token mit Zugriff auf `Match-Secrets` (Lesen und Schreiben) |
| `MATCH_PASSWORD` | Passwort, mit dem `Match-Secrets` verschlüsselt ist |

#### Fastfile (Kern)
```ruby
def match_settings(readonly:)
  {
    type: "appstore",
    git_url: "https://github.com/#{ENV['GITHUB_REPOSITORY_OWNER']}/Match-Secrets",
    git_basic_authorization: Base64.strict_encode64("#{ENV['GITHUB_REPOSITORY_OWNER']}:#{ENV['GH_PAT']}"),
    app_identifier: [APP_ID, "#{APP_ID}.widget"],
    team_id: ENV["TEAMID"],
    api_key: api_key,          # app_store_connect_api_key aus FASTLANE_KEY_*
    readonly: readonly
  }
end
```
- `app_identifier` enthält **nur** die Bundle-IDs dieser App. Dadurch ändert `match` keine
  Profile der anderen Apps.
- Nach einer Capability-Änderung (z. B. neuer iCloud-Container) wird `3-create-certificates`
  mit `force: true` ausgeführt. Das erneuert nur die Profile dieser App, nicht das Zertifikat.
- **Niemals `match nuke`** oder neue Verteilungszertifikate aus diesem Repo heraus erzeugen. Das
  würde das gemeinsame Zertifikat widerrufen, und Loop, Trio, xDrip4iOS, LoopFollow und
  InsulinOCR müssten alle neu signiert werden.
- Läuft das gemeinsame Zertifikat ab, wird es zentral erneuert (wie bei den anderen Apps), danach
  laufen hier `3-create-certificates` und `4-testflight` erneut.

#### Weitere Details
- Runner: macOS-Image von GitHub mit Xcode 26, feste Xcode-Version per `xcode-select`.
- fastlane-Version per `Gemfile`/`Gemfile.lock` festgelegt, mindestens die Version, mit der
  `Match-Secrets` zuletzt geschrieben wurde (2.241.1).
- Build-Nummer: `latest_testflight_build_number + 1`, Versionsnummer aus dem Tag.
- `pilot` mit `skip_waiting_for_build_processing`, Verteilung an die interne Gruppe, Changelog
  aus den Commits seit dem letzten Tag.
- Der monatliche Lauf sorgt dafür, dass nie alle Builds gleichzeitig ablaufen.
- Das Repo `management-timer` ist öffentlich: Workflows mit Secrets laufen nur auf Branches
  dieses Repos und nie für Pull Requests aus Forks.

---

## 10. Umsetzung in Phasen

| Phase | Ergebnis | Abnahme |
|---|---|---|
| **0 – Gerüst** | Xcode-Projekt (iOS 26), Targets, Packages, App Group, Keychain-Sharing, iCloud-Container, fastlane, `ci.yml`, Workflows 1–3 gegen `Match-Secrets`, Spike SwiftData + CloudKit mit Widget-Extension | Leere App und Widget bauen, Tests laufen in GitHub Actions, Profile für App und Widget liegen in `Match-Secrets`, Testdatensatz synchronisiert zwischen zwei Geräten |
| **1 – Anbindung** | Einrichtung, `NightscoutKit` (v3 + v1), Fähigkeitserkennung, Lesen der letzten Wechsel | Verbindung zu einem echten Server, Timer zeigen echte Daten |
| **2 – Timer** | `TimerCore` inkl. Schlauch-Timer, Übersicht, Schwellen vom Server und lokal, Verlauf | Unit-Tests für Statusberechnung inkl. Zeitzonen- und DST-Fällen |
| **3 – Eintragen** | Wechsel loggen, „Schlauch auch gewechselt“, Offline-Queue, Duplikatschutz, Korrigieren/Löschen, Rückgängig | Nightscout-Eintrag erscheint genau einmal. Schlauch-Eintrag erscheint auf dem zweiten Gerät, nie in Nightscout |
| **4 – Erinnerungen** | AlarmKit-Spike, Benachrichtigungen, Alarme, Countdown-Live-Activity, Aktionen, Ruhezeiten, Hintergrund-Abgleich | Alarm klingelt im Stummmodus, „Jetzt gewechselt“ funktioniert aus Benachrichtigung, Alarm und Live Activity |
| **5 – Widgets & Intents** | Lock- und Home-Screen-Widgets, CarPlay, Kontrollzentrum, Siri/Kurzbefehle mit Snippets | Widget und Control aktualisieren sich nach Eintrag aus jeder Quelle, auch von einem anderen Gerät |
| **6 – TestFlight** | Lokalisierung, Barrierefreiheit, App-Icon, CloudKit-Schema in Production, `4-testflight.yml` | Build über TestFlight für interne Tester installierbar, Schlauch-Sync funktioniert im TestFlight-Build |

---

## 11. Tests

- **Unit-Tests (Swift Testing):** Timer-Status, Schwellenübernahme, Erinnerungsplan (welche
  Stufe über welchen Mechanismus, Ruhezeiten, Snooze), JSON-Dekodierung (Beispielantworten von
  v1 und v3 als Fixtures), Offline-Queue, **Schlauch-Einträge werden nie in die Queue
  aufgenommen**, „Schlauch auch gewechselt“ erzeugt genau einen `TubingChange`.
- **Integrationstests:** gegen einen lokalen Nightscout per Docker (`nightscout/cgm-remote-monitor`
  + MongoDB), Lesen, Schreiben, Duplikatschutz, Token-Rollen. Laufen lokal, in der CI optional.
- **UI-Tests:** Einrichtung, Wechsel eintragen, Rückgängig.
- **Manuell auf echten Geräten:** AlarmKit im Stummmodus und mit Fokus, Live Activity im
  Dynamic Island, CarPlay-Widget (Simulator), Kontrollzentrum, **iCloud-Sync zwischen zwei
  Geräten** (auch nach Offline-Phase und mit abgemeldetem iCloud).

---

## 12. Risiken

| Risiko | Gegenmaßnahme |
|---|---|
| Server-Versionen unterscheiden sich (v3 fehlt, Felder fehlen) | Fähigkeitserkennung, v1-Fallback, tolerante Dekodierung |
| Hintergrund-Abgleich ist unzuverlässig | Erinnerungen sind lokal geplant und funktionieren trotzdem. Beim Öffnen der App wird sofort abgeglichen |
| Wechsel wird von einer anderen App oder einem anderen Gerät eingetragen, Alarm ist noch alt geplant | Neuplanung nach jedem Abgleich. Bis dahin kann ein überflüssiger Alarm kommen, der Alarm zeigt deshalb „Zuletzt abgeglichen: …“ |
| Countdown vor einem terminierten Alarm technisch eingeschränkt | Spike in Phase 4, notfalls Countdown erst kurz vor Fälligkeit oder nur Alarm ohne Countdown |
| SwiftData + CloudKit zusammen mit einer Widget-Extension (zwei Prozesse) | Spike in Phase 0, Extension schreibt nicht direkt in den CloudKit-Store, Rückfallebene JSON-Snapshot |
| CloudKit-Schema nicht in Production übertragen | Fester Schritt in der Release-Checkliste, Phase-6-Abnahme prüft Sync im TestFlight-Build |
| iCloud nicht verfügbar oder andere Apple-ID | Timer funktioniert lokal weiter, iCloud-Status in den Einstellungen und auf der Karte |
| Versehentlicher Eintrag per Widget oder Control | Bestätigung im Control, Rückgängig-Funktion, Eintrag mit eigener ID löschbar |
| Token mit zu vielen Rechten | Einrichtung empfiehlt die Rolle `careportal` und warnt bei `API_SECRET` |
| TestFlight-Builds laufen nach 90 Tagen ab | Monatlicher automatischer Upload per GitHub Actions |
| Gemeinsames Zertifikat in `Match-Secrets` wird versehentlich widerrufen | Kein `match nuke`, `app_identifier` nur mit eigenen Bundle-IDs, Workflow 4 nur `readonly: true` |
| Gemeinsames Zertifikat oder API-Schlüssel läuft ab | Zentrale Erneuerung wie bei Loop und Trio, danach Workflows 3 und 4 neu ausführen |
| Capability fehlt im Profil (z. B. iCloud-Container nicht zugeordnet) | Workflow 2 legt Capabilities an. Was die API nicht kann (Zuordnung des iCloud-Containers), wird einmalig im Developer-Portal erledigt, danach Workflow 3 mit `force: true` |
| Zeitzonen und Uhrumstellung | UTC intern, `utcOffset` beim Schreiben, eigene Testfälle |

---

## 13. Entscheidungen

| Thema | Entscheidung |
|---|---|
| Plattform | iOS, Mindestversion iOS 26 |
| Fokus | Wechsel-Timer |
| Nightscout | genau ein Server |
| Schlauch-Timer | über iCloud (private CloudKit-Datenbank), nie Nightscout |
| Schlauch-Schwellen | 5 / 6 / 7 Tage (Warnung nach 6 Tagen) |
| „Schlauch auch gewechselt“ | standardmäßig an |
| Countdown-Vorlauf | 2 Stunden vor „dringend“ |
| Verteilung | TestFlight, nur interne Tester |
| CI / Upload | GitHub Actions mit fastlane (`match`, `gym`, `pilot`) |
| Signierung | bestehendes Repo `feebleeDIYorg/Match-Secrets`, gemeinsames Verteilungszertifikat, eigene Profile |

## 14. Offene Punkte

- **Bundle-ID:** Vorschlag nach dem Muster von InsulinOCR `ch.feebleediy.managementtimer` mit
  `ch.feebleediy.managementtimer.widget`, App Group `group.ch.feebleediy.managementtimer` und
  iCloud-Container `iCloud.ch.feebleediy.managementtimer`. Alternativ das Muster der
  Loop-Forks mit der Team-ID im Namen.
- **Secrets:** Sind `TEAMID`, `FASTLANE_*`, `GH_PAT` und `MATCH_PASSWORD` schon
  Organisations-Secrets in `feebleeDIYorg`, oder müssen sie in diesem Repo angelegt werden?
- **App-Name:** „Wechsel-Timer“ als Arbeitstitel, oder ein anderer Name für TestFlight?

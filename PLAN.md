# Plan: Wechsel-Timer für Nightscout (iOS)

Eine iOS-App, die anhand der Careportal-Daten eines Nightscout-Servers anzeigt, wie lange
Kanüle, Sensor, Insulin und Pumpenbatterie schon in Gebrauch sind. Sie trägt neue Wechsel in
Nightscout ein und erinnert rechtzeitig per Widget, Benachrichtigung und Alarm. Zusätzlich gibt
es einen rein lokalen Timer für den Schlauch, für den Nightscout keinen Ereignistyp kennt.

> **Hinweis:** Die App ist kein Medizinprodukt. Sie berechnet keine Dosen und gibt keine
> BZ-Alarme aus, sie verwaltet nur Wechsel-Erinnerungen.

## Eckdaten

| | |
|---|---|
| Plattform | iPhone, **Mindestversion iOS 26** (iPhone 11 und neuer) |
| Nightscout | **genau ein Server** |
| Verteilung | **TestFlight** (kein App Store) |
| Sprache / UI | Swift 6, SwiftUI im Liquid-Glass-Design |

---

## 1. Umfang

### Im Umfang (MVP)
| Bereich | Inhalt |
|---|---|
| **Timer** | Kanüle (CAGE), Sensor (SAGE), Insulin (IAGE), Pumpenbatterie (BAGE) aus Nightscout, dazu **Schlauch (nur lokal)**. Jeder mit Ampelstatus (ok / Info / Warnung / dringend) und Zeit bis zum nächsten Wechsel |
| **Eintragen** | Ein Tipp auf „Kanüle gewechselt“ usw., optional mit abweichendem Zeitpunkt und Notiz. Eigene Einträge lassen sich korrigieren oder löschen |
| **Verlauf** | Liste der letzten Wechsel je Typ, durchschnittliche Tragedauer |
| **Benachrichtigungen** | Lokal geplante Erinnerungen für Info und Warnung, mit Aktionen direkt aus der Benachrichtigung |
| **Alarme (AlarmKit)** | Stufe „dringend“ als echter Alarm, der auch im Stummmodus klingelt |
| **Countdown (Live Activity)** | Countdown im Dynamic Island und auf dem Sperrbildschirm, bevor ein Wechsel dringend wird |
| **Widgets** | Home- und Lock-Screen-Widgets, auch in **CarPlay**, mit interaktivem Button „Gewechselt“ |
| **Kontrollzentrum** | Steuerelement „Gewechselt“ pro Timer |
| **Siri / Kurzbefehle / Spotlight** | App Intents mit **interaktiver Bestätigung** („Kanüle jetzt als gewechselt eintragen?“) |

### Bewusst nicht im Umfang
- BZ-Werte, Bolus, KH, Basalraten. Dafür gibt es xDrip4iOS, Loop, Trio usw.
- Mehrere Nightscout-Server
- Synchronisierung des Schlauch-Timers (weder Nightscout noch iCloud)
- Eigenes Push-Backend
- Android, App Store

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
| **Schlauch** | **nur lokal** | lokales Ereignis `tubingChange` | einstellbar, Vorschlag 120 h / 144 h / 168 h (siehe offene Punkte) |

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

### Schlauch-Timer (nur lokal)
- Nightscout hat keinen Ereignistyp für den Schlauchwechsel. Der Timer existiert deshalb **nur
  auf dem Gerät**. Es gibt keinen Upload nach Nightscout und keine iCloud-Synchronisierung.
- Die Wechsel werden in der lokalen Datenbank mit `source = .local` gespeichert. Die Offline-Queue
  nimmt sie nie auf, der Nightscout-Abgleich ignoriert sie.
- Ein Schlauchwechsel wird meist zusammen mit einem Kanülenwechsel gemacht. Beim Eintragen von
  „Kanüle gewechselt“ gibt es deshalb einen Schalter **„Schlauch auch gewechselt“**. Der
  Standardwert ist einstellbar: immer an, immer aus oder „an, wenn der Schlauch die Info-Schwelle
  erreicht hat“.
- Alles andere funktioniert wie bei den Nightscout-Timern: Widget, Benachrichtigung, Alarm,
  Countdown, Kontrollzentrum, Siri.
- **Datenverlust:** Die Daten stecken nur im normalen Geräte-Backup (iCloud- oder
  Computer-Backup). Ein Neuinstallieren der App setzt den Schlauch-Timer zurück. Die
  Einrichtung fragt dann nach dem letzten Wechsel, die Einstellungen weisen darauf hin.

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
  Widget- und Intent-Code sie mitnutzen können.
- Es gibt genau eine Server-Konfiguration. Ein Serverwechsel in den Einstellungen löscht den
  Nightscout-Cache, die lokalen Schlauch-Daten bleiben erhalten.

---

## 4. Architektur

```
┌──────────────────────────── App ─────────────────────────────┐
│  SwiftUI-Ansichten (Übersicht, Verlauf, Einstellungen)       │
│                            ↕                                 │
│  ChangeStore (Observable) ── Offline-Queue (nur Nightscout)  │
│        ↕                   ↕                                 │
│  NightscoutClient       SwiftData (App-Group-Container)      │
│                         ├─ Nightscout-Cache                  │
│                         └─ lokale Ereignisse (Schlauch)      │
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
| `TimerCore` | Timer-Typen (Nightscout und lokal), Schwellen, Statusberechnung, Erinnerungsplan | Foundation |
| `Persistence` | SwiftData-Modelle, Offline-Queue, App-Group-Zugriff | TimerCore |
| `ChangeIntents` | `LogChangeIntent`, `UndoChangeIntent`, `RefreshIntent`, Snippet-Ansichten | alle |

### Datenmodell (Kern)
```swift
enum TimerKind: String, Codable { case cannula, sensor, insulin, battery, tubing }

enum TimerSource { case nightscout(eventTypes: [String]), local }

@Model final class ChangeEvent {
    var id: UUID            // = Nightscout-identifier bei source == .nightscout
    var kind: TimerKind
    var date: Date          // UTC
    var note: String?
    var origin: Origin      // .nightscout, .local
    var enteredByThisApp: Bool
    var syncState: SyncState // .synced, .pending, .localOnly
}
```
`TimerKind.tubing` hat immer `TimerSource.local` und `syncState == .localOnly`.

### Targets
- **App** (iOS 26)
- **Widget-Extension**: Widgets, Kontrollzentrum-Steuerelemente, Live Activity für AlarmKit
- **Unit-Tests** (Swift Testing) und **UI-Tests** (XCTest)

### Datenabgleich
1. **App im Vordergrund:** Abgleich beim Start, bei Pull-to-Refresh und nach jedem Eintrag.
2. **Hintergrund:** `BGAppRefreshTask` (iOS bestimmt den Zeitpunkt). Damit werden Wechsel
   erkannt, die andere Apps eingetragen haben.
3. **Offline:** Eigene Einträge landen sofort in der lokalen DB und, nur bei Nightscout-Timern,
   in der Queue. Timer, Widgets und Erinnerungen werden direkt aktualisiert, das Senden passiert,
   sobald wieder Netz da ist.
4. Nach jeder Änderung: Widget-Timelines und Controls neu laden und alle Erinnerungen neu
   planen.

---

## 5. Erinnerungen: Benachrichtigungen, Alarme, Countdown

Alle Erinnerungen werden **lokal geplant**, ein Push-Server ist nicht nötig. Nightscout kann
Apps keine Push-Nachrichten senden, aber die Wechselzeitpunkte stehen vorher fest. Nach jedem
Abgleich oder Eintrag berechnet `TimerCore` einen Erinnerungsplan, und der `ReminderScheduler`
ersetzt damit alle bisherigen Erinnerungen. Das ist idempotent und testbar.

### Stufen
| Stufe | Mechanismus | Verhalten |
|---|---|---|
| Info | Benachrichtigung (`active`) | Banner, respektiert Ruhezeiten |
| Warnung | Benachrichtigung (`timeSensitive`) | Banner, respektiert Ruhezeiten |
| Countdown | AlarmKit-Countdown als Live Activity | erscheint eine einstellbare Zeit vor „dringend“ (Standard 2 h) im Dynamic Island und auf dem Sperrbildschirm |
| Dringend | **AlarmKit-Alarm** | klingelt auch im Stummmodus und bei Fokus, Vollbild-Alarm |

Jede Stufe lässt sich pro Timer abschalten. Wer keinen AlarmKit-Zugriff erlaubt, bekommt für
„dringend“ stattdessen eine `timeSensitive`-Benachrichtigung.

### Aktionen
- **Benachrichtigungen:** „Jetzt gewechselt“ (trägt ohne App-Start ein), „In 1 Std. erinnern“,
  „Morgen früh erinnern“.
- **Alarm:** Hauptbutton „Jetzt gewechselt“ (über `LiveActivityIntent`), zweiter Button
  „Später“ (Schlummern, einstellbare Dauer).
- **Live Activity:** Button „Gewechselt“ direkt im Countdown.

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
  Activity), wie lange er laufen darf, und ob die Systemgrenzen für Live Activities den
  Standard von 2 h zulassen.

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

- `LogChangeIntent(kind:, date:, note:)` mit **interaktivem Snippet**: zeigt das aktuelle Alter
  und fragt „Jetzt als gewechselt eintragen?“ mit den Buttons „Eintragen“ und „Abbrechen“.
- Beim Kanülenwechsel zeigt das Snippet zusätzlich den Schalter „Schlauch auch gewechselt“.
- `GetTimerStatusIntent(kind:)` gibt Alter und Status zurück, z. B. für eigene Automationen in
  Kurzbefehlen.
- App Shortcuts mit deutschen und englischen Phrasen („Kanüle gewechselt in Wechsel-Timer“).

---

## 8. Bedienung

- **Übersicht:** Je Timer eine Karte mit Ampelring, Alter und „fällig in …“. Der Schlauch-Timer
  trägt ein kleines Symbol „nur auf diesem Gerät“. Langes Drücken öffnet „Gewechselt um …“
  (abweichende Uhrzeit) und Notiz.
- **Verlauf:** Liste je Typ, Tragedauer pro Wechsel, Durchschnitt der letzten 10.
- **Einstellungen:** Server und Token, Verbindungstest, Timer an/aus, Schwellen, Erinnerungs-
  stufen pro Timer, Countdown-Vorlauf, Ruhezeiten, Standardwert für „Schlauch auch gewechselt“.
- **Einrichtung:** URL → Token → Test → Schwellen übernehmen → letzter Schlauchwechsel
  (optional) → Benachrichtigungen erlauben → Alarme erlauben.
- Liquid-Glass-Design mit Systemkomponenten, Lokalisierung Deutsch und Englisch
  (String Catalog), Dynamic Type, VoiceOver und Farbenblindheit (Ampel zusätzlich mit Symbol).

---

## 9. Verteilung über TestFlight

- Voraussetzung: Mitgliedschaft im **Apple Developer Program**, App-Eintrag in App Store Connect
  (wird nicht veröffentlicht).
- **Interne Tester** (Mitglieder des Teams in App Store Connect) bekommen Builds ohne Prüfung
  durch Apple. **Externe Tester** brauchen eine Beta-App-Prüfung für die erste Version und bei
  größeren Änderungen.
- TestFlight-Builds laufen nach **90 Tagen** ab. Für eine Alltags-App heißt das: regelmäßig neue
  Builds hochladen. Das übernimmt die CI (Xcode Cloud oder GitHub Actions mit fastlane), z. B.
  bei jedem Tag `v*` und zusätzlich monatlich.
- Entitlements und Capabilities: App Groups, Keychain Sharing, Background Modes (Background
  fetch), Push nicht nötig. AlarmKit braucht nur den Info.plist-Eintrag.
- Beta-Beschreibung und Testhinweise enthalten den Hinweis „kein Medizinprodukt“ und eine
  Anleitung zum Anlegen des `careportal`-Tokens.

---

## 10. Umsetzung in Phasen

| Phase | Ergebnis | Abnahme |
|---|---|---|
| **0 – Gerüst** | Xcode-Projekt (iOS 26), Targets, Packages, App Group, Keychain-Sharing, CI (Build + Tests) | Leere App und Widget bauen, Tests laufen |
| **1 – Anbindung** | Einrichtung, `NightscoutKit` (v3 + v1), Fähigkeitserkennung, Lesen der letzten Wechsel | Verbindung zu einem echten Server, Timer zeigen echte Daten |
| **2 – Timer** | `TimerCore` inkl. lokalem Schlauch-Timer, Übersicht, Schwellen vom Server und lokal, Verlauf | Unit-Tests für Statusberechnung inkl. Zeitzonen- und DST-Fällen |
| **3 – Eintragen** | Wechsel loggen, „Schlauch auch gewechselt“, Offline-Queue, Duplikatschutz, Korrigieren/Löschen, Rückgängig | Nightscout-Eintrag erscheint genau einmal, Schlauch-Eintrag erscheint nie in Nightscout |
| **4 – Erinnerungen** | AlarmKit-Spike, Benachrichtigungen, Alarme, Countdown-Live-Activity, Aktionen, Ruhezeiten, Hintergrund-Abgleich | Alarm klingelt im Stummmodus, „Jetzt gewechselt“ funktioniert aus Benachrichtigung, Alarm und Live Activity |
| **5 – Widgets & Intents** | Lock- und Home-Screen-Widgets, CarPlay, Kontrollzentrum, Siri/Kurzbefehle mit Snippets | Widget und Control aktualisieren sich nach Eintrag aus jeder Quelle |
| **6 – TestFlight** | Lokalisierung, Barrierefreiheit, App-Icon, Upload-Pipeline, erste interne Version | Build installierbar über TestFlight |

---

## 11. Tests

- **Unit-Tests (Swift Testing):** Timer-Status, Schwellenübernahme, Erinnerungsplan (welche
  Stufe über welchen Mechanismus, Ruhezeiten, Snooze), JSON-Dekodierung (Beispielantworten von
  v1 und v3 als Fixtures), Offline-Queue, **Schlauch-Ereignisse werden nie in die Queue
  aufgenommen**.
- **Integrationstests:** gegen einen lokalen Nightscout per Docker (`nightscout/cgm-remote-monitor`
  + MongoDB), Lesen, Schreiben, Duplikatschutz, Token-Rollen.
- **UI-Tests:** Einrichtung, Wechsel eintragen, Rückgängig.
- **Manuell auf echtem Gerät:** AlarmKit im Stummmodus und mit Fokus, Live Activity im Dynamic
  Island, CarPlay-Widget (Simulator), Kontrollzentrum.

---

## 12. Risiken

| Risiko | Gegenmaßnahme |
|---|---|
| Server-Versionen unterscheiden sich (v3 fehlt, Felder fehlen) | Fähigkeitserkennung, v1-Fallback, tolerante Dekodierung |
| Hintergrund-Abgleich ist unzuverlässig | Erinnerungen sind lokal geplant und funktionieren trotzdem. Beim Öffnen der App wird sofort abgeglichen |
| Wechsel wird von einer anderen App eingetragen, Alarm ist noch alt geplant | Neuplanung nach jedem Abgleich. Bis zum nächsten Abgleich kann ein überflüssiger Alarm kommen, der Alarm zeigt deshalb „Zuletzt abgeglichen: …“ |
| Countdown vor einem terminierten Alarm technisch eingeschränkt | Spike in Phase 4, notfalls Countdown erst kurz vor Fälligkeit oder nur Alarm ohne Countdown |
| Schlauch-Daten gehen bei Neuinstallation verloren | Hinweis in Einstellungen, Abfrage des letzten Wechsels in der Einrichtung |
| Versehentlicher Eintrag per Widget oder Control | Bestätigung im Control, Rückgängig-Funktion, Eintrag mit eigener `identifier` löschbar |
| Token mit zu vielen Rechten | Einrichtung empfiehlt die Rolle `careportal` und warnt bei `API_SECRET` |
| TestFlight-Builds laufen nach 90 Tagen ab | Automatischer Upload per CI, Erinnerung im Kalender |
| Zeitzonen und Uhrumstellung | UTC intern, `utcOffset` beim Schreiben, eigene Testfälle |

---

## 13. Offene Punkte

- **Schwellen für den Schlauch:** Welche Standardwerte (Vorschlag 120 h / 144 h / 168 h)? Das
  hängt vom Schlauchsystem und den Angaben des Herstellers ab.
- **Standard für „Schlauch auch gewechselt“:** immer an, immer aus oder abhängig vom Alter?
- **Countdown-Vorlauf:** Ist 2 h vor „dringend“ sinnvoll, oder lieber ab der Warnung?
- **Externe Tester:** Nur interne Tester, oder auch externe (dann mit Beta-App-Prüfung)?
- **CI:** Xcode Cloud oder GitHub Actions mit fastlane für den TestFlight-Upload?

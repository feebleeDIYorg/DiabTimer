# Plan: Wechsel-Timer für Nightscout (iOS)

Eine iOS-App, die anhand der Careportal-Daten eines Nightscout-Servers anzeigt, wie lange
Kanüle, Sensor, Insulin und Pumpenbatterie schon in Gebrauch sind. Sie trägt neue Wechsel in
Nightscout ein und erinnert rechtzeitig per Widget und Benachrichtigung.

> **Hinweis:** Die App ist kein Medizinprodukt. Sie berechnet keine Dosen und gibt keine
> BZ-Alarme aus, sie verwaltet nur Wechsel-Erinnerungen.

---

## 1. Umfang

### Im Umfang (MVP)
| Bereich | Inhalt |
|---|---|
| **Timer** | Alter von Kanüle (CAGE), Sensor (SAGE), Insulin (IAGE) und Pumpenbatterie (BAGE) mit Ampelstatus (ok / Info / Warnung / dringend) und Zeit bis zum nächsten Wechsel |
| **Eintragen** | Ein Tipp auf „Kanüle gewechselt“ usw., optional mit abweichendem Zeitpunkt und Notiz. Eigene Einträge lassen sich korrigieren oder löschen |
| **Verlauf** | Liste der letzten Wechsel je Typ, durchschnittliche Tragedauer |
| **Widgets** | Home- und Lock-Screen-Widgets mit Timern, interaktiver Button „Jetzt gewechselt“ |
| **Benachrichtigungen** | Lokal geplante Erinnerungen je Schwelle, Aktionen direkt aus der Benachrichtigung |

### Bewusst nicht im Umfang
- BZ-Werte, Bolus, KH, Basalraten. Dafür gibt es xDrip4iOS, Loop, Trio usw.
- Eigenes Push-Backend
- Android

### Später denkbar
- Apple-Watch-Komplikation, Control-Center-Steuerelemente (iOS 18)
- Mehrere Nightscout-Server (z. B. für Eltern/Betreuende)
- Vorratsverwaltung („noch 3 Sensoren übrig“)

---

## 2. Timer-Logik

| Timer | Nightscout-Ereignis (`eventType`) | Standard-Schwellen (Info / Warnung / dringend) |
|---|---|---|
| Kanüle (CAGE) | `Site Change` | 44 h / 48 h / 72 h |
| Sensor (SAGE) | jüngstes von `Sensor Start` und `Sensor Change` | 144 h / 164 h / 166 h |
| Insulin (IAGE) | `Insulin Change` | 44 h / 48 h / 72 h |
| Batterie (BAGE) | `Pump Battery Change` | 312 h / 336 h / 360 h |

- Die Schwellen werden beim Einrichten aus `/api/v1/status.json` übernommen
  (`settings.extendedSettings.cage.warn` usw.), sofern der Server sie liefert. Sonst gelten die
  Standardwerte oben. In der App lassen sie sich pro Timer überschreiben.
- Einzelne Timer lassen sich ausblenden (z. B. Batterie bei Patch-Pumpen).
- Das Alter wird immer lokal aus dem Zeitstempel berechnet (`now - created_at`). Für die Anzeige
  sind keine Netzwerkzugriffe nötig.
- Zeit wird intern in UTC gespeichert. So rechnen die Timer auch nach Zeitzonenwechseln und der
  Sommer-/Winterzeit-Umstellung richtig.

Die Timer-Logik ist eine reine Funktion `(letzterWechsel, schwellen, jetzt) -> TimerStatus`.
App, Widget und Benachrichtigungsplanung nutzen sie gemeinsam, und sie lässt sich vollständig
per Unit-Test prüfen.

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
- Token, Secret und JWT werden im **Keychain** gespeichert, mit einer Access Group, damit das
  Widget sie mitnutzen kann.

---

## 4. Architektur

```
┌───────────────────────── App ──────────────────────────┐
│  SwiftUI-Ansichten (Übersicht, Verlauf, Einstellungen) │
│                         ↕                              │
│  ChangeStore (Observable) ── Offline-Queue             │
│        ↕                ↕                              │
│  NightscoutClient     SwiftData (App-Group-Container)  │
└───────┬─────────────────┬──────────────────────────────┘
        │                 ├──► Widget-Extension (liest Cache, App Intents)
   Nightscout             └──► NotificationScheduler (UNUserNotificationCenter)
```

### Module (lokale Swift Packages)
| Modul | Aufgabe | Abhängigkeiten |
|---|---|---|
| `NightscoutKit` | API-Client (v1/v3), Auth, DTOs, Fähigkeitserkennung | Foundation |
| `TimerCore` | Timer-Typen, Schwellen, Statusberechnung, Notification-Plan | Foundation |
| `Persistence` | SwiftData-Modelle, Offline-Queue, App-Group-Zugriff | TimerCore |
| `AppIntents` (geteilt) | `LogChangeIntent`, `RefreshIntent` für App, Widget, Kurzbefehle | alle |

### Targets
- **App** (iOS 17+, SwiftUI)
- **Widget-Extension** (WidgetKit, interaktive Widgets mit App Intents)
- **Unit-Tests** (Swift Testing) und **UI-Tests** (XCTest)

### Datenabgleich
1. **App im Vordergrund:** Abgleich beim Start, bei Pull-to-Refresh und nach jedem Eintrag.
2. **Hintergrund:** `BGAppRefreshTask` (iOS bestimmt den Zeitpunkt). Damit werden Wechsel
   erkannt, die andere Apps eingetragen haben.
3. **Offline:** Eigene Einträge landen sofort in der lokalen DB und in der Queue. Timer, Widget
   und Benachrichtigungen werden direkt aktualisiert, das Senden passiert sobald Netz da ist.
4. Nach jeder Änderung: Widget-Timelines neu laden (`WidgetCenter.shared.reloadAllTimelines()`)
   und Benachrichtigungen neu planen.

---

## 5. Benachrichtigungen

- **Lokal geplant**, kein Push-Server nötig. Nightscout kann Apps keine Push-Nachrichten
  senden, aber die Wechselzeitpunkte stehen vorher fest.
- Pro aktivem Timer bis zu drei Erinnerungen (Info, Warnung, dringend) mit
  `UNTimeIntervalNotificationTrigger`. Das bleibt weit unter dem iOS-Limit von 64 geplanten
  Benachrichtigungen.
- Nach jedem Abgleich oder Eintrag werden alle Erinnerungen gelöscht und neu geplant. Die
  Planung ist idempotent und testbar (`TimerCore` liefert den Plan, die App setzt ihn um).
- **Aktionen in der Benachrichtigung:** „Jetzt gewechselt“ (trägt den Wechsel ohne App-Start
  ein), „In 1 Std. erinnern“, „Morgen früh erinnern“.
- **Ruhezeiten:** Erinnerungen, die nachts fällig würden, werden auf eine einstellbare Uhrzeit
  verschoben. Ausgenommen ist die Stufe „dringend“.
- Die Stufe „dringend“ nutzt die Unterbrechungsstufe `timeSensitive`. Kritische Warnungen
  (Critical Alerts) bräuchten eine Sondergenehmigung von Apple und sind nicht vorgesehen.

---

## 6. Widgets

| Größe | Inhalt |
|---|---|
| Lock Screen (rund/rechteckig) | Ein Timer als Ring mit Restzeit bzw. kompakte Liste |
| Klein | Ein frei wählbarer Timer, Ampelfarbe, Alter, Button „Gewechselt“ |
| Mittel | Alle aktiven Timer nebeneinander |
| Groß (optional) | Timer und letzter Wechsel mit Datum |

- Das Alter wird mit `Text(date, style: .relative)` angezeigt und läuft ohne Timeline-Updates
  weiter. Timeline-Einträge gibt es nur an den Schwellenzeitpunkten, wenn die Farbe wechselt.
- Konfiguration per `AppIntentConfiguration` (welcher Timer).
- Der Button „Gewechselt“ löst `LogChangeIntent` aus. Bei versehentlichem Tippen kann der
  Eintrag in der App rückgängig gemacht werden.

---

## 7. Bedienung

- **Übersicht:** Je Timer eine Karte mit Ampelring, Alter und „fällig in …“. Langes Drücken
  öffnet „Gewechselt um …“ (abweichende Uhrzeit) und Notiz.
- **Verlauf:** Liste je Typ, Tragedauer pro Wechsel, Durchschnitt der letzten 10.
- **Einstellungen:** Server und Token, Verbindungstest, Timer an/aus, Schwellen, Ruhezeiten,
  Benachrichtigungsstufen.
- **Einrichtung:** URL → Token → Test → Schwellen übernehmen → Benachrichtigungen erlauben.
- Lokalisierung Deutsch und Englisch (String Catalog), Dynamic Type, VoiceOver und
  Farbenblindheit (Ampel zusätzlich mit Symbol).

---

## 8. Umsetzung in Phasen

| Phase | Ergebnis | Abnahme |
|---|---|---|
| **0 – Gerüst** | Xcode-Projekt, Targets, Packages, App Group, Keychain-Sharing, CI (GitHub Actions: Build + Tests) | Leere App und Widget bauen, Tests laufen |
| **1 – Anbindung** | Einrichtung, `NightscoutKit` (v3 + v1), Fähigkeitserkennung, Lesen der letzten Wechsel | Verbindung zu einem echten Server, Timer zeigen echte Daten |
| **2 – Timer** | `TimerCore`, Übersicht, Schwellen vom Server und lokal, Verlauf | Unit-Tests für Statusberechnung inkl. Zeitzonen- und DST-Fällen |
| **3 – Eintragen** | Wechsel loggen, Offline-Queue, Duplikatschutz, Korrigieren/Löschen | Eintrag erscheint in Nightscout, auch nach Offline-Phase genau einmal |
| **4 – Benachrichtigungen** | Planung, Aktionen, Snooze, Ruhezeiten, Hintergrund-Abgleich | Erinnerung kommt zur richtigen Zeit, „Jetzt gewechselt“ trägt ein |
| **5 – Widgets** | Lock-Screen-, kleine und mittlere Widgets, interaktiver Button | Widget aktualisiert sich nach Eintrag aus App und Benachrichtigung |
| **6 – Feinschliff** | Lokalisierung, Barrierefreiheit, App-Icon, TestFlight | Interner TestFlight-Build |

---

## 9. Tests

- **Unit-Tests (Swift Testing):** Timer-Status, Schwellenübernahme, Notification-Plan,
  JSON-Dekodierung (Beispielantworten von v1 und v3 als Fixtures), Offline-Queue.
- **Integrationstests:** gegen einen lokalen Nightscout per Docker (`nightscout/cgm-remote-monitor`
  + MongoDB), Lesen, Schreiben, Duplikatschutz, Token-Rollen.
- **UI-Tests:** Einrichtung, Wechsel eintragen, Rückgängig.

---

## 10. Risiken

| Risiko | Gegenmaßnahme |
|---|---|
| Server-Versionen unterscheiden sich (v3 fehlt, Felder fehlen) | Fähigkeitserkennung, v1-Fallback, tolerante Dekodierung |
| Hintergrund-Abgleich ist unzuverlässig | Erinnerungen sind lokal geplant und funktionieren trotzdem. Beim Öffnen der App wird sofort abgeglichen |
| Andere Apps (AAPS, Loop) tragen dieselben Ereignisse ein | Immer den jüngsten Eintrag verwenden, egal von wem. Fremde Einträge nur lesen |
| Versehentlicher Eintrag per Widget | Rückgängig-Funktion in der App, Eintrag mit eigener `identifier` löschbar |
| Token mit zu vielen Rechten | Einrichtung empfiehlt die Rolle `careportal` und warnt bei `API_SECRET` |
| Zeitzonen und Uhrumstellung | UTC intern, `utcOffset` beim Schreiben, eigene Testfälle |

---

## 11. Offene Punkte

- Nur ein Server oder später mehrere (Betreuende)? Das Datenmodell sieht vorerst einen Server
  vor, ist aber so geschnitten, dass sich weitere ergänzen lassen.
- Mindestversion iOS 17 (interaktive Widgets, SwiftData) oder iOS 18 (Control-Center-
  Steuerelemente)?
- Verteilung: nur TestFlight/privat oder App Store? Das bestimmt Datenschutzangaben und
  App-Review-Aufwand.

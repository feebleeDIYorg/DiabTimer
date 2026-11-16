# Plan: DiabTimer für Nightscout (iOS)

Eine iOS-App, die anhand der Careportal-Daten eines Nightscout-Servers anzeigt, wie lange
Kanüle, Sensor, Insulin und Pumpenbatterie schon in Gebrauch sind. Sie trägt neue Wechsel in
Nightscout ein und erinnert rechtzeitig per Widget, Benachrichtigung und (ab Version 2) Alarm.
Zusätzlich gibt es einen Timer für den Schlauch. Für ihn kennt Nightscout keinen Ereignistyp,
deshalb wird er nicht über Nightscout, sondern über **iCloud** zwischen den eigenen Geräten
synchronisiert.

> **Hinweis:** Die App ist kein Medizinprodukt. Sie berechnet keine Dosen und gibt keine
> BZ-Alarme aus, sie verwaltet nur Wechsel-Erinnerungen.

## Eckdaten

| | |
|---|---|
| App-Name | **DiabTimer** |
| Plattform | iPhone, **Mindestversion iOS 26** (iPhone 11 und neuer) |
| Nightscout | **genau ein Server**, Version 15 oder neuer, **nur API v3** |
| Schlauch-Timer | **iCloud-Schlüssel-Wert-Speicher**, nie Nightscout |
| Verteilung | **TestFlight, nur interne Tester** |
| Entwicklung | **alles über den Browser-Build** (GitHub Actions), kein lokales Xcode nötig |
| CI / Upload | GitHub Actions mit fastlane, Aufbau wie im Loop-Fork `feebleeDIYorg/LoopWorkspace` |
| Signierung | bestehendes Repo `feebleeDIYorg/Match-Secrets`, Organisations-Secrets |
| Sprache / UI | Swift 6, SwiftUI im Liquid-Glass-Design |

---

## 1. Umfang in drei Versionen

Der Umfang ist gestaffelt. Jede Version ist für sich benutzbar und geht über TestFlight raus.

### Version 1: Timer, Eintragen, Benachrichtigungen, Widget
| Bereich | Inhalt |
|---|---|
| **Timer** | Kanüle (CAGE), Sensor (SAGE), Insulin (IAGE), Pumpenbatterie (BAGE) aus Nightscout, dazu Schlauch über iCloud. Jeder mit Status (ok / Info / Warnung / dringend) und Zeit bis zum nächsten Wechsel |
| **Eintragen** | Kombi-Dialog „Wechsel eintragen“ für mehrere Teile gleichzeitig, optional mit abweichendem Zeitpunkt und Notiz, „Rückgängig“ vor dem Senden |
| **Verlauf** | Die letzten 20 Wechsel je Typ, durchschnittliche Tragedauer der letzten 10 |
| **Benachrichtigungen** | Lokal geplant für alle drei Stufen, gebündelt, mit Aktionen, Schlummern und täglicher Wiederholung bei Überfälligkeit |
| **Widgets** | Home Screen (klein, mittel) und Lock Screen, mit Button „Gewechselt“ (zwei Tipps) |

### Version 2: Alarm und Countdown
| Bereich | Inhalt |
|---|---|
| **Alarm (AlarmKit)** | Stufe „dringend“ als echter Alarm, der auch im Stummmodus klingelt, pro Timer einschaltbar |
| **Countdown (Live Activity)** | Countdown im Dynamic Island und auf dem Sperrbildschirm, 2 Stunden vor „dringend“ |

### Version 3: Schnellzugriffe
| Bereich | Inhalt |
|---|---|
| **Kontrollzentrum** | Steuerelement „Gewechselt“ pro Timer |
| **Siri / Kurzbefehle / Spotlight** | App Intents mit interaktiver Bestätigung |
| **CarPlay** | Timer-Widget, nur Anzeige |

Ob AlarmKit und der Countdown so funktionieren wie geplant, wird trotzdem schon in Phase 0
getestet, weil das Ergebnis das Design der Erinnerungen beeinflusst.

### Bewusst nicht im Umfang
- BZ-Werte, Bolus, KH, Basalraten. Dafür gibt es xDrip4iOS, Loop, Trio usw.
- Mehrere Nightscout-Server
- Nightscout API v1 und Anmeldung mit `API_SECRET`
- Upload des Schlauch-Timers nach Nightscout
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
| Sensor (SAGE) | Nightscout | jüngstes von `Sensor Start` und `Sensor Change` | nach Sensortyp, siehe unten |
| Insulin (IAGE) | Nightscout | `Insulin Change` | 44 h / 48 h / 72 h |
| Batterie (BAGE) | Nightscout | `Pump Battery Change` | 312 h / 336 h / 360 h |
| Schlauch | iCloud | Schlauchwechsel (nur in der App) | 120 h / 144 h / 168 h (5 / 6 / 7 Tage) |

### Gemeinsame Regeln
- **Schwellen vom Server:** `GET /api/v1/status.json` liefert die konfigurierten Werte unter
  `extendedSettings.cage`, `.sage`, `.iage`, `.bage` (jeweils `info`, `warn`, `urgent`). Das ist
  der einzige v1-Aufruf der App, weil v3 diese Werte nicht ausgibt. Fehlt ein Wert, gelten die
  Standardwerte oben (sie entsprechen denen von Nightscout). Die Werte werden bei der
  Einrichtung übernommen und auf Wunsch über „Vom Server übernehmen“ aktualisiert. In der App
  lassen sie sich pro Timer überschreiben.
- **Sensor-Schwellen:** Die Nightscout-Standards (144 h / 164 h / 166 h) stammen von
  7-Tage-Sensoren. Hat der Server keine eigenen `sage`-Werte, fragt die Einrichtung nach der
  Laufzeit des Sensors (Vorschläge: 10 Tage, 10,5 Tage, 14 Tage, 15 Tage, eigener Wert) und
  setzt Info auf 24 h, Warnung auf 6 h und dringend auf 2 h vor Ablauf.
- Einzelne Timer lassen sich ausblenden (z. B. Batterie bei Patch-Pumpen, Schlauch bei
  schlauchlosen Pumpen).
- Das Alter wird immer lokal aus dem Zeitstempel berechnet (`jetzt − letzterWechsel`). Für die
  Anzeige sind keine Netzwerkzugriffe nötig.
- Zeit wird intern in UTC gespeichert. So rechnen die Timer auch nach Zeitzonenwechseln und der
  Sommer-/Winterzeit-Umstellung richtig.
- Die Timer-Logik ist eine reine Funktion `(letzterWechsel, schwellen, jetzt) -> TimerStatus`.
  App, Widgets und Erinnerungen nutzen sie gemeinsam. Sie lässt sich vollständig per Unit-Test
  prüfen.

### Schlauch-Timer (über iCloud)
- Gespeichert im **iCloud-Schlüssel-Wert-Speicher** (`NSUbiquitousKeyValueStore`): ein Schlüssel
  mit den letzten 20 Schlauchwechseln als JSON, dazu eine Liste gelöschter IDs. Das braucht kein
  CloudKit-Schema, keinen iCloud-Container und keine Push-Berechtigung.
- **Abgleich:** Meldet iCloud eine Änderung von einem anderen Gerät, werden beide Listen über
  die IDs zusammengeführt (Vereinigung, gelöschte IDs gewinnen). So geht kein Eintrag verloren,
  wenn zwei Geräte kurz nacheinander schreiben.
- **Grenzen:** iCloud bestimmt, wann abgeglichen wird, das kann einige Sekunden bis Minuten
  dauern. Die Historie ist auf 20 Einträge begrenzt.
- **Ohne iCloud** (abgemeldet oder iCloud für die App aus) funktioniert der Timer weiter, nur
  ohne Abgleich. Die Einstellungen zeigen den iCloud-Status an.
- Nach einer Neuinstallation oder auf einem neuen Gerät kommen die Daten aus iCloud zurück. Nur
  wenn dort nichts liegt, fragt die Einrichtung nach dem letzten Schlauchwechsel.

### Schlauch mit der Kanüle wechseln
Der Schlauch hält länger als die Kanüle. Wäre „Schlauch auch gewechselt“ immer an, würde der
Schlauch-Timer bei jedem Kanülenwechsel zurückgesetzt und seine Schwellen nie erreichen.
Deshalb gilt:
- Der Schalter „Schlauch auch gewechselt“ ist **an, wenn der Schlauch älter ist als die
  Einstellung „Schlauch mitwechseln ab“** (Standard: 4 Tage), sonst aus. Er lässt sich bei jedem
  Eintrag umstellen.
- Die Einstellung kennt außerdem „immer“ und „nie“.
- **Kanülenwechsel aus einer anderen App:** Erkennt der Abgleich einen neuen `Site Change`, der
  nicht von DiabTimer stammt, und ist der Schlauch älter als die Einstellung, fragt eine
  Benachrichtigung „Kanüle wurde gewechselt. Schlauch auch?“ mit den Aktionen „Ja“ und „Nein“.
  Der Schlauchwechsel bekommt dann denselben Zeitpunkt wie der Kanülenwechsel.

---

## 3. Nightscout-Anbindung (API v3)

### Aufrufe
| Zweck | Aufruf |
|---|---|
| Version und Rechte prüfen | `GET /api/v3/status` liefert die Version und unter `apiPermissions.treatments` die Rechte des Tokens (`c`, `r`, `u`, `d`) |
| Schwellen lesen | `GET /api/v1/status.json` (siehe Abschnitt 2) |
| Erstbefüllung | je Ereignistyp `GET /api/v3/treatments?eventType$eq=Site%20Change&sort$desc=date&limit=20` |
| Abgleich | `GET /api/v3/treatments/history/{lastModified}` liefert alle seitdem geänderten Einträge, auch gelöschte |
| Eintragen | `POST /api/v3/treatments` |
| Korrigieren | `PATCH /api/v3/treatments/{identifier}` |
| Löschen | `DELETE /api/v3/treatments/{identifier}` |

### Eintrag
```json
{
  "eventType": "Site Change",
  "date": 1794817800000,
  "utcOffset": 60,
  "app": "DiabTimer",
  "device": "DiabTimer",
  "enteredBy": "DiabTimer",
  "created_at": "2026-11-16T08:30:00.000Z",
  "notes": "optional"
}
```
- `date` und `app` sind in v3 Pflichtfelder, ohne `app` lehnt der Server den Eintrag ab.
- **Kennung:** Der Server berechnet die `identifier` selbst aus `device`, `date` und
  `eventType`. Die App legt `date` beim Antippen einmal fest und sendet bei einer Wiederholung
  exakt dieselben Werte. Der Server erkennt den Eintrag dann wieder und legt kein Duplikat an.
- **Wiederholung nach Netzwerkfehler:** Trifft ein wiederholter Eintrag auf einen bereits
  gespeicherten, ersetzt der Server ihn. Dafür verlangt er das Recht `update`. Hat das Token
  dieses Recht nicht, prüft die App vor der Wiederholung per Suche (`date$eq`, `eventType$eq`,
  `device$eq`), ob der Eintrag schon angekommen ist.
- **Eigene Einträge** erkennt die App an `app == "DiabTimer"`. Nur diese bietet sie zum
  Korrigieren und Löschen an.

### Gelöschte und geänderte Einträge
- v3 löscht nicht wirklich, sondern setzt `isValid: false`. Der Abgleich über `history` liefert
  solche Einträge mit. Die App entfernt sie aus ihrem Bestand, der Timer fällt auf den
  vorherigen Wechsel zurück, und die Erinnerungen werden neu geplant.
- Wird der Zeitpunkt eines Eintrags in Nightscout geändert, kommt er ebenfalls über `history`
  und wird übernommen.

### Anmeldung und Rechte
- Anmeldung nur mit einem **Nightscout-Zugriffstoken** (Admin-Werkzeuge → Subjects). Die App
  tauscht es über `/api/v2/authorization/request/<token>` gegen ein JWT und sendet dieses als
  `Authorization: Bearer`. Läuft das JWT ab, wird es automatisch erneuert.
- Die Standardrolle `careportal` erlaubt **nur das Anlegen** von Einträgen, weder Lesen noch
  Korrigieren noch Löschen. Empfohlen wird deshalb eine eigene Rolle:

  | Rolle `diabtimer` (Admin-Werkzeuge → Roles) |
  |---|
  | `api:status:read`, `api:treatments:read`, `api:treatments:create`, `api:treatments:update`, `api:treatments:delete` |

  Sie gibt der App alles, was sie braucht, und keinen Zugriff auf BZ-Werte oder Profile.
- **Mindestvariante:** die Standardrollen `readable` und `careportal` zusammen. Dann kann die
  App lesen und eintragen, aber bereits gesendete Einträge nicht korrigieren oder löschen. Die
  App erkennt das an `apiPermissions` und blendet diese Funktionen aus.
- Fehlt das Leserecht oder das Recht zum Anlegen, meldet die Einrichtung das mit einer
  Anleitung, statt später stumm zu scheitern.
- Token und JWT liegen im **Keychain** mit einer Access Group, damit die Widget-Extension sie
  mitnutzen kann. Sie werden nicht über den iCloud-Schlüsselbund geteilt, auf jedem Gerät wird
  der Server einmal eingerichtet.
- Es gibt genau eine Server-Konfiguration. Ein Serverwechsel löscht den Nightscout-Bestand der
  App, die Schlauch-Daten bleiben erhalten.

---

## 4. Eintragen

### Grundsatz
**Kein Eintrag verlässt das Gerät durch einen einzelnen Tipp.** Andere Clients (Loop, Trio,
AAPS, Nightscout-Web) lesen dieselben Einträge, ein versehentlicher Wechsel soll dort gar nicht
erst ankommen.

| Ort | Schutz |
|---|---|
| App | Eintrag gilt sofort lokal, wird aber erst nach **15 Sekunden** gesendet. Solange zeigt die App „Rückgängig“. Wechselt die App in den Hintergrund, wird sofort gesendet |
| Widget | Zwei Tipps: Der erste Tipp macht aus dem Button für einige Sekunden „Wirklich? ✓ ✗“, erst der zweite sendet |
| Benachrichtigung | Die Aktion „Jetzt gewechselt“ liegt hinter langem Drücken und sendet direkt |
| Kontrollzentrum, Siri (Version 3) | Bestätigungsdialog bzw. Snippet |

Nach dem Senden lässt sich ein eigener Eintrag korrigieren oder löschen, sofern das Token die
Rechte `update` und `delete` hat.

### Kombi-Dialog „Wechsel eintragen“
- Ein Dialog mit Häkchen für **Kanüle, Schlauch, Insulin, Sensor, Batterie**, gemeinsamem
  Zeitpunkt (Standard: jetzt) und Notiz.
- Ein Tipp auf eine Timer-Karte öffnet den Dialog mit diesem Teil vorausgewählt. Bei Kanüle ist
  der Schlauch nach der Regel aus Abschnitt 2 mit angehakt.
- Einstellung „Insulin mit der Kanüle wechseln“ (Standard: aus) hakt auch das Insulin mit an.
- Jedes angehakte Teil wird ein eigener Eintrag mit demselben Zeitpunkt: Nightscout-Teile als
  je ein Treatment, der Schlauch in iCloud.

### Offline
Einträge landen sofort im lokalen Bestand und in einer Warteschlange. Timer, Widgets und
Erinnerungen stimmen sofort. Gesendet wird, sobald wieder Netz da ist. Schlauch-Einträge kommen
nie in die Warteschlange.

---

## 5. Architektur

```
┌──────────────────────────── App ─────────────────────────────┐
│  SwiftUI-Ansichten (Übersicht, Verlauf, Einstellungen)       │
│                            ↕                                 │
│  ChangeStore (Observable) ── Warteschlange (nur Nightscout)  │
│        ↕                ↕                    ↕               │
│  NightscoutClient   Bestandsdatei       TubingSync ──────────┼──► iCloud
│                     (App Group, JSON)   (Schlüssel-Wert)     │    (privat)
└───────┬─────────────────┬────────────────────────────────────┘
        │                 ├──► Widget-Extension (liest Bestandsdatei, App Intents)
   Nightscout             └──► ReminderScheduler
                                 ├─ UNUserNotificationCenter (Version 1)
                                 └─ AlarmKit (Version 2)
```

### Speicherung
Die Datenmenge ist winzig (höchstens 20 Einträge je Timer). Deshalb gibt es keine Datenbank,
sondern **eine JSON-Datei im App-Group-Container**:

```swift
enum TimerKind: String, Codable { case cannula, sensor, insulin, battery, tubing }

struct ChangeEvent: Codable, Identifiable {
    var id: String          // Nightscout-identifier bzw. UUID beim Schlauch
    var kind: TimerKind
    var date: Date          // UTC
    var note: String?
    var isOwn: Bool         // von DiabTimer eingetragen
    var sync: SyncState     // .synced, .pending(sendAfter:), .iCloud
}

struct AppState: Codable {
    var events: [TimerKind: [ChangeEvent]]   // je Typ die letzten 20
    var lastModified: Date?                  // für den history-Abgleich
    var snoozes: [TimerKind: Date]           // „erinnere später“
    var thresholds: [TimerKind: Thresholds]
    var lastSync: Date?
}
```
- App und Widget-Extension lesen und schreiben die Datei über dieselbe Klasse aus dem Paket
  `Persistence`, abgesichert mit `NSFileCoordinator` und atomarem Schreiben.
- Der Nightscout-Teil lässt sich jederzeit aus dem Server neu aufbauen.
- **iCloud greift nur die App an.** Trägt das Widget einen Schlauchwechsel ein, schreibt es ihn
  in die Bestandsdatei. Die App überträgt ihn beim nächsten Start oder Hintergrundlauf in den
  iCloud-Speicher.

### Module (lokale Swift Packages)
| Modul | Aufgabe | läuft unter Linux |
|---|---|---|
| `TimerCore` | Timer-Typen, Schwellen, Statusberechnung, Erinnerungsplan | ja |
| `NightscoutKit` | API-Client (v3), Anmeldung, DTOs, Rechteprüfung | ja |
| `Persistence` | Bestandsdatei, Warteschlange, App-Group-Zugriff, iCloud-Abgleich | teilweise (Zusammenführen ja, iCloud nein) |
| `ChangeIntents` | `LogChangeIntent`, `RefreshIntent`, ab Version 3 Snippets | nein |

`TimerCore` und `NightscoutKit` hängen nur von Foundation ab. Ihre Tests laufen dadurch auch auf
einem Linux-Runner in Sekunden, ohne Xcode.

### Projektdatei
Das Xcode-Projekt wird mit **XcodeGen** aus einer `project.yml` erzeugt und nicht eingecheckt.
Die Projektbeschreibung bleibt damit lesbar und lässt sich ohne Xcode pflegen. CI und ein
lokaler Mac rufen vor dem Bauen `xcodegen generate` auf.

### Targets
- **App** (iOS 26)
- **Widget-Extension**: Widgets, ab Version 2 Live Activity, ab Version 3 Steuerelemente
- **Unit-Tests** (Swift Testing) und **UI-Tests** (XCTest)

### Datenabgleich
1. **App im Vordergrund:** Nightscout-Abgleich beim Start, bei Pull-to-Refresh und nach jedem
   Eintrag. iCloud meldet Änderungen von selbst.
2. **Hintergrund:** `BGAppRefreshTask`. iOS bestimmt den Zeitpunkt. Die App fordert den
   nächsten Lauf jeweils kurz vor der nächsten Warn- oder Dringend-Schwelle an, damit ein
   Wechsel aus einer anderen App möglichst vor der Erinnerung bekannt ist.
3. Nach jeder Änderung aus Nightscout, iCloud oder einem eigenen Eintrag: Widgets neu laden
   und Erinnerungen neu planen.

---

## 6. Erinnerungen

Alle Erinnerungen werden **lokal geplant**, ein eigener Push-Server ist nicht nötig. Nightscout
kann Apps keine Push-Nachrichten senden, aber die Wechselzeitpunkte stehen vorher fest.

### Planung
`TimerCore` berechnet aus **Timerständen, Schwellen, Schlummer-Zeiten, Ruhezeiten und
Einstellungen** einen vollständigen Erinnerungsplan. Der `ReminderScheduler` ersetzt damit alle
bisher geplanten Erinnerungen. Weil die Schlummer-Zeiten Teil der Eingabe sind und in der
Bestandsdatei stehen, überleben sie jede Neuplanung.

| Regel | Verhalten |
|---|---|
| **Nur Zukünftiges** | Geplant werden nur Schwellen, die noch bevorstehen. Bereits überschrittene Schwellen lösen bei der Planung nichts aus (z. B. direkt nach der Einrichtung) |
| **Bündeln** | Erinnerungen, die innerhalb von 30 Minuten fällig werden, kommen als eine Meldung („Kanüle und Insulin fällig“) mit der höchsten beteiligten Stufe |
| **Überfällig** | Ist „dringend“ überschritten und nicht gewechselt, erinnert die App **täglich** zu einer einstellbaren Uhrzeit (Standard 09:00), bis der Wechsel eingetragen ist |
| **Schlummern** | „In 1 Std. erinnern“ und „Morgen früh erinnern“ setzen eine Schlummer-Zeit für diesen Timer. Bis dahin entfallen seine Erinnerungen, danach kommt genau eine |
| **Ruhezeit, Info und Warnung** | werden auf das Ende der Ruhezeit verschoben |
| **Ruhezeit, dringend** | wird auf 30 Minuten **vor Beginn** der Ruhezeit vorgezogen, damit nichts nachts klingelt und trotzdem rechtzeitig erinnert wird |
| **Stand** | Jede Meldung nennt, wann zuletzt mit Nightscout abgeglichen wurde |

### Stufen
| Stufe | Version 1 | ab Version 2 |
|---|---|---|
| Info | Benachrichtigung (`active`) | unverändert |
| Warnung | Benachrichtigung (`timeSensitive`) | unverändert |
| Countdown | – | Live Activity, 2 Stunden vor „dringend“ (einstellbar) |
| Dringend | Benachrichtigung (`timeSensitive`) | AlarmKit-Alarm, wenn für den Timer eingeschaltet, sonst wie Version 1 |

Jede Stufe lässt sich pro Timer abschalten.

### Aktionen
- **Benachrichtigung:** „Jetzt gewechselt“, „In 1 Std. erinnern“, „Morgen früh erinnern“. Bei
  gebündelten Meldungen gilt die Aktion für alle genannten Timer.
- **Alarm (Version 2):** Hauptbutton „Jetzt gewechselt“, zweiter Button „Später“.
- **Live Activity (Version 2):** Button „Gewechselt“.
- Bei Kanüle gilt die Schlauch-Regel aus Abschnitt 2.

### Wechsel aus anderen Apps und Fehlalarme
Trägt eine andere App den Wechsel ein und hat DiabTimer im Hintergrund noch nicht abgeglichen,
kann eine Erinnerung trotz erledigtem Wechsel kommen. Ohne eigenen Server lässt sich das nicht
ganz verhindern. Gegenmaßnahmen:
- gezielter Hintergrund-Abgleich kurz vor jeder Warn- und Dringend-Schwelle,
- Angabe „zuletzt abgeglichen“ in der Meldung,
- der laute AlarmKit-Alarm ist **pro Timer einzeln einschaltbar und standardmäßig aus**. Die
  Einrichtung empfiehlt ihn für Timer, deren Wechsel in DiabTimer eingetragen werden.

### AlarmKit (Version 2)
- `NSAlarmKitUsageDescription` in der Info.plist, Erlaubnis über
  `AlarmManager.shared.requestAuthorization()` mit Erklärung.
- Alarm mit festem Zeitpunkt zur Schwelle „dringend“, Darstellung über `AlarmPresentation` und
  `AlarmAttributes`, Ansichten in der Widget-Extension.
- Je Timer höchstens ein Alarm. Fallen mehrere zusammen, wird wie bei den Benachrichtigungen
  gebündelt. Für den Alarm gelten dieselben Regeln zu Ruhezeit und Schlummern.
- **Test in Phase 0:** Wie lässt sich der Countdown vor einem terminierten Alarm starten
  (Vor-Countdown von AlarmKit oder eigene Live Activity), wie lange darf er laufen, klingelt
  der Alarm im Stummmodus und bei Fokus? Das Ergebnis wird hier nachgetragen.

---

## 7. Widgets

### Version 1
| Ort | Inhalt |
|---|---|
| Lock Screen (rund/rechteckig) | Ein Timer als Ring mit Restzeit bzw. kompakte Liste |
| Home Screen klein | Ein frei wählbarer Timer, Statusfarbe, Alter, Button „Gewechselt“ |
| Home Screen mittel | Alle aktiven Timer nebeneinander |

- Alter und Ring laufen von selbst weiter: `Text(date, style: .relative)` für das Alter und
  `ProgressView(timerInterval:)` für den Ring. Timeline-Einträge gibt es nur an den
  Schwellenzeitpunkten, wenn die Farbe wechselt.
- Konfiguration per `AppIntentConfiguration` (welcher Timer, auch Schlauch).
- Darstellung in den Liquid-Glass-Varianten (getönt, klar).
- Der Button „Gewechselt“ braucht zwei Tipps (siehe Abschnitt 4).

### Version 3
| Ort | Inhalt |
|---|---|
| Kontrollzentrum | Steuerelement pro Timer, Tippen trägt den Wechsel nach Bestätigung ein |
| CarPlay | Kompakte Timer-Liste, nur Anzeige |
| Siri, Kurzbefehle, Spotlight | `LogChangeIntent` mit Snippet „Jetzt als gewechselt eintragen?“, `GetTimerStatusIntent` für eigene Automationen, App Shortcuts auf Deutsch und Englisch |

---

## 8. Bedienung

- **Übersicht:** Je Timer eine Karte mit Statusring, Alter und „fällig in …“. Der Schlauch-Timer
  trägt ein kleines iCloud-Symbol, durchgestrichen wenn iCloud nicht verfügbar ist. Tippen
  öffnet den Kombi-Dialog.
- **Verlauf:** Liste je Typ, Tragedauer pro Wechsel, Durchschnitt der letzten 10. Fremde
  Einträge zeigen, aus welcher App sie stammen.
- **Einstellungen:** Server und Token, Verbindungstest mit Anzeige der Rechte, iCloud-Status,
  Timer an/aus, Schwellen („Vom Server übernehmen“), Erinnerungsstufen pro Timer, Ruhezeiten,
  Uhrzeit für Überfällig-Erinnerungen, „Schlauch mitwechseln ab“, „Insulin mit der Kanüle
  wechseln“. Ab Version 2: Alarm pro Timer, Countdown-Vorlauf.
- **Einrichtung:** URL → Token → Prüfung von Version und Rechten → Schwellen übernehmen →
  Sensor-Laufzeit (falls der Server keine Werte hat) → letzter Schlauchwechsel (nur wenn in
  iCloud nichts liegt) → Benachrichtigungen erlauben. Ab Version 2: Alarme erlauben.
- Liquid-Glass-Design mit Systemkomponenten, Lokalisierung Deutsch und Englisch
  (String Catalog), Dynamic Type, VoiceOver und Farbenblindheit (Status zusätzlich mit Symbol).

---

## 9. Entwicklung und Verteilung

### Entwicklungsweg: alles über den Browser-Build
- Gebaut, getestet und verteilt wird ausschließlich über **GitHub Actions**. Ein lokales Xcode
  ist nicht nötig. Ein Mac mit Xcode ist vorhanden und dient nur als Ausweg, falls ein Fehler
  sich anders nicht eingrenzen lässt.
- Getestet wird auf dem iPhone über **TestFlight**. `Match-Secrets` enthält nur
  Verteilungsprofile, Entwicklungsprofile werden nicht gebraucht.
- Damit das schnell genug geht:
  - Die Logik steckt in Paketen, deren Tests in Sekunden auf einem Linux-Runner laufen.
  - Der App-Build und die UI-Tests laufen im Simulator auf dem macOS-Runner.
  - Schon Phase 0 endet mit einem TestFlight-Build, damit Signierung, Berechtigungen und die
    gerätenahen Funktionen früh geprüft sind.

### TestFlight (nur intern)
- Voraussetzung: Mitgliedschaft im **Apple Developer Program**, App-Eintrag in App Store Connect
  (wird nicht veröffentlicht).
- **Nur interne Tester:** Personen aus dem App-Store-Connect-Team (bis zu 100). Builds stehen
  ohne Beta-App-Prüfung durch Apple zur Verfügung.
- TestFlight-Builds laufen nach **90 Tagen** ab. Die CI baut deshalb mindestens monatlich.
- **Capabilities:** App Groups und iCloud (nur Schlüssel-Wert-Speicher). Kein iCloud-Container,
  kein Push. Background Modes: Background fetch. Keychain Sharing braucht keine Capability im
  Portal. AlarmKit braucht ab Version 2 nur den Info.plist-Eintrag.
- Testhinweise in TestFlight enthalten den Hinweis „kein Medizinprodukt“ und die Anleitung zum
  Anlegen der Rolle `diabtimer` und des Tokens.

### Bezeichner nach dem Muster des Loop-Forks

Wie in `feebleeDIYorg/LoopWorkspace` setzt sich jede Bundle-ID aus der Team-ID zusammen. Die
Team-ID steht dadurch nirgends im öffentlichen Repo, sie kommt nur aus dem Secret `TEAMID`.

| Bezeichner | Wert | Vorbild im Loop-Fork |
|---|---|---|
| App | `com.<TEAMID>.DiabTimer` | `com.<TEAMID>.loopkit.Loop` |
| Widget-Extension | `com.<TEAMID>.DiabTimer.DiabTimerWidgetExtension` | `com.<TEAMID>.loopkit.Loop.LoopWidgetExtension` |
| App Group | `group.com.<TEAMID>.DiabTimerGroup` | `group.com.<TEAMID>.loopkit.LoopGroup` |
| iCloud-Schlüssel-Wert-Speicher | `$(TeamIdentifierPrefix)com.<TEAMID>.DiabTimer` | (Loop hat keinen) |
| Anzeigename | `DiabTimer` | `MAIN_APP_DISPLAY_NAME` |

```
// DiabTimerConfig.xcconfig  (wie LoopConfigOverride.xcconfig)
MAIN_APP_BUNDLE_IDENTIFIER = com.$(DEVELOPMENT_TEAM).DiabTimer
MAIN_APP_DISPLAY_NAME = DiabTimer
APP_GROUP_IDENTIFIER = group.com.$(DEVELOPMENT_TEAM).DiabTimerGroup

// VersionOverride.xcconfig  (wie im Loop-Fork)
MARKETING_VERSION = 0.1.0
CURRENT_PROJECT_VERSION = 1
```
`DEVELOPMENT_TEAM` setzt die CI per `update_project_team` aus `TEAMID`. Für einen lokalen Build
trägt man die eigene Team-ID in einer nicht eingecheckten `DiabTimerConfig.local.xcconfig` ein.

### CI: Aufbau wie im Loop-Fork, mit dem bestehenden `Match-Secrets`-Repo

Für die Signierung wird das **bestehende private Repo `feebleeDIYorg/Match-Secrets`**
verwendet (fastlane match, Typ `appstore`). Dort liegt bereits das Verteilungszertifikat, das
auch die anderen Apps der Organisation nutzen. DiabTimer bekommt dort nur **zusätzliche
Profile**.

Dateien und Workflows werden aus `feebleeDIYorg/LoopWorkspace` übernommen und angepasst. Die
Herkunft wird im Kopf jeder übernommenen Datei genannt.

| Datei | Herkunft im Loop-Fork | Anpassung |
|---|---|---|
| `fastlane/Matchfile` | `fastlane/Matchfile` | unverändert |
| `fastlane/Fastfile` | `fastlane/Fastfile` | gleiche Lanes ohne `nuke_certs`, Bundle-IDs und Targets von DiabTimer |
| `Gemfile`, `Gemfile.lock` | gleich | gleiche fastlane-Version wie im Loop-Fork |
| `.github/workflows/validate_secrets.yml` | **1. Validate Secrets** | Bundle-ID |
| `.github/workflows/add_identifiers.yml` | **2. Add Identifiers** | zusätzlich `xcodegen generate` |
| `.github/workflows/create_certs.yml` | **3. Create Certificates** | ohne Nuke-Job |
| `.github/workflows/build_diabtimer.yml` | **4. Build Loop Manual** | ohne Upstream-Sync und Patches |
| `.github/workflows/build_diabtimer_auto.yml` | **4. Build Loop Auto** | eigene Prüfung auf neue Commits, siehe unten |
| `.github/workflows/ci.yml` | (neu) | siehe unten |
| `fastlane/testflight.md` | `fastlane/testflight.md` | Anleitung für DiabTimer |

#### Fastfile-Lanes
| Lane | Aufgabe | Zugriff auf `Match-Secrets` |
|---|---|---|
| `identifiers` | Legt die Bundle-IDs an und ergänzt fehlende Capabilities (Hilfsfunktion `configure_bundle_id` wie im Loop-Fork) | keiner |
| `certs` | `match(type: "appstore", force: false, app_identifier: [App, Widget])`: legt fehlende oder abgelaufene Profile für DiabTimer an | **schreibend**, nur für die beiden Bundle-IDs von DiabTimer |
| `check_and_renew_certificates` | Prüft, ob das Verteilungszertifikat gültig ist | keiner |
| `validate_secrets` | API-Schlüssel prüfen, `match` mit leerer `app_identifier`-Liste | lesend |
| `build_diabtimer` | `setup_ci`, `update_project_team`, Build-Nummer = `latest_testflight_build_number + 1`, `match`, `update_code_signing_settings` für App und Widget, `gym` | lesend |
| `release` | `upload_to_testflight` mit `skip_waiting_for_build_processing: true` | keiner |

```ruby
configure_bundle_id("DiabTimer", "com.#{TEAMID}.DiabTimer", [
  Spaceship::ConnectAPI::BundleIdCapability::Type::APP_GROUPS,
  Spaceship::ConnectAPI::BundleIdCapability::Type::ICLOUD
])

configure_bundle_id("DiabTimer Widget Extension",
  "com.#{TEAMID}.DiabTimer.DiabTimerWidgetExtension", [
  Spaceship::ConnectAPI::BundleIdCapability::Type::APP_GROUPS
])
```

#### Workflows im Detail
- **Runner und Xcode** wie im Loop-Fork: `ubuntu-26.04` für die Prüf-Jobs, `xcode-27` mit
  `xcode-select` auf `Xcode_27.0.app` für alles mit fastlane. Gebaut wird mit dem SDK von
  Xcode 27, die Mindestversion bleibt iOS 26. Ob das Label `xcode-27` in diesem Repo verfügbar
  ist, zeigt der erste Lauf in Phase 0. Ausweichlösung ist das aktuelle macOS-Image von GitHub.
- **`ci.yml`** bei jedem Push und Pull Request, ohne Secrets:
  1. Linux-Job: `swift test` für `TimerCore` und `NightscoutKit`.
  2. macOS-Job: `xcodegen generate`, Build und Tests im Simulator.
- **Schritte im Build:** `xcodegen generate`, „Patch Match Tables“, `bundle install`,
  „Sync clock“, `fastlane build_diabtimer`, `fastlane release`, Upload von `DiabTimer.ipa` und
  Build-Log als Artefakt.
- **`create_certs.yml`** wird wie im Loop-Fork vor jedem Build aufgerufen. Es schreibt nur,
  wenn ein Profil von DiabTimer fehlt oder abgelaufen ist.
- **Zeitplan:** Prüfung jeden Sonntag (`cron: "33 7 * * 0"`). Gebaut wird,
  - am **2. Sonntag im Monat** (Repo-Variable `SCHEDULED_BUILD`, Standard an), oder
  - wenn `main` neue Commits seit dem letzten TestFlight-Build hat (Repo-Variable
    `BUILD_ON_NEW_COMMITS`, Standard an). Dafür setzt der Build nach dem Upload den Git-Tag
    `testflight-latest` auf den gebauten Commit, die Prüfung vergleicht ihn mit `main`.
- **Zeitplan am Leben halten:** GitHub schaltet geplante Workflows ab, wenn ein Repo 60 Tage
  ohne Aktivität ist. Der Auto-Build aktiviert sich deshalb bei jedem Lauf über die GitHub-API
  selbst neu (`GH_PAT` hat das Recht `workflow`). Zusätzlich warnt der monatliche Build in
  seiner Zusammenfassung, wenn der letzte TestFlight-Build älter als 60 Tage ist.
- **Kein Nuke:** Im Loop-Fork kann `create_certs.yml` bei abgelaufenem Zertifikat `match nuke`
  ausführen. In DiabTimer gibt es weder den Job noch die Lane. Das Zertifikat wird zentral im
  Loop-Fork erneuert. Meldet `check_and_renew_certificates` ein abgelaufenes Zertifikat, bricht
  der Build mit einem Hinweis darauf ab.
- Das Repo ist öffentlich: Workflows mit Secrets laufen nur auf Branches dieses Repos und nie
  für Pull Requests aus Forks.

#### Secrets und Variablen
Die Secrets bestehen bereits als **Organisations-Secrets in `feebleeDIYorg`** und sind für alle
Repositories freigegeben. In diesem Repo ist nichts einzurichten.

| Secret | Inhalt |
|---|---|
| `TEAMID` | Apple-Team-ID |
| `FASTLANE_KEY_ID` | ID des App-Store-Connect-API-Schlüssels |
| `FASTLANE_ISSUER_ID` | Issuer-ID des API-Schlüssels |
| `FASTLANE_KEY` | Inhalt der `.p8`-Datei |
| `GH_PAT` | GitHub-Token mit den Rechten `repo` und `workflow` |
| `MATCH_PASSWORD` | Passwort, mit dem `Match-Secrets` verschlüsselt ist |

| Repo-Variable | Bedeutung |
|---|---|
| `SCHEDULED_BUILD` | `false` schaltet den monatlichen Build ab |
| `BUILD_ON_NEW_COMMITS` | `false` schaltet den Build bei neuen Commits ab |

#### Einmalige Einrichtung (wie bei Loop)
1. Workflow **1. Validate Secrets** ausführen.
2. Workflow **2. Add Identifiers** ausführen.
3. Im Apple-Developer-Portal die App Group `group.com.<TEAMID>.DiabTimerGroup` anlegen und
   beiden Bundle-IDs zuordnen (wie bei Loop ein manueller Schritt).
4. In App Store Connect die App „DiabTimer“ mit der Bundle-ID `com.<TEAMID>.DiabTimer` anlegen
   und eine interne Testgruppe einrichten.
5. Workflow **3. Create Certificates** ausführen.
6. Workflow **4. Build DiabTimer** ausführen.

Nach späteren Änderungen an Capabilities: Schritte 2, 3 und 5 wiederholen und `certs` einmalig
mit `force: true` ausführen. Das erneuert nur die Profile von DiabTimer, nicht das Zertifikat.

---

## 10. Umsetzung in Phasen

| Phase | Version | Ergebnis | Abnahme |
|---|---|---|---|
| **0 – Gerüst und Tests am Gerät** | – | `project.yml`, Targets, Packages, App Group, fastlane, alle Workflows, einmalige Einrichtung. Test-App mit drei Proben: AlarmKit mit Countdown, iCloud-Schlüssel-Wert-Speicher, Widget liest Bestandsdatei | Erster Build über TestFlight installiert. Runner-Label geklärt. Ergebnisse der drei Proben im Plan nachgetragen |
| **1 – Anbindung** | 1 | Einrichtung, `NightscoutKit` (v3), Rechteprüfung, Erstbefüllung, `history`-Abgleich inkl. gelöschter Einträge | Timer zeigen echte Daten. Ein in Nightscout gelöschter Wechsel verschwindet aus der App |
| **2 – Timer** | 1 | `TimerCore`, Übersicht, Schwellen vom Server, Sensor-Laufzeit, Schlauch-Timer mit iCloud, Verlauf | Unit-Tests für Statusberechnung inkl. Zeitzonen und Uhrumstellung. Schlauchwechsel erscheint auf einem zweiten Gerät |
| **3 – Eintragen** | 1 | Kombi-Dialog, Schlauch-Regel, 15-Sekunden-Rückgängig, Warteschlange, Wiederholung ohne Duplikat, Korrigieren/Löschen | Eintrag erscheint genau einmal in Nightscout, auch nach Offline-Phase. Rückgängig innerhalb von 15 s hinterlässt nichts auf dem Server |
| **4 – Benachrichtigungen** | 1 | Erinnerungsplan mit Bündeln, Schlummern, Überfällig, Ruhezeiten. Hintergrund-Abgleich, Nachfrage bei fremdem Kanülenwechsel | Unit-Tests für alle Regeln aus Abschnitt 6. Aktionen funktionieren ohne App-Start |
| **5 – Widgets** | 1 | Lock- und Home-Screen-Widgets, Button mit zwei Tipps, Lokalisierung, Barrierefreiheit, App-Icon | **Version 1 in TestFlight.** Widget aktualisiert sich nach Eintrag aus jeder Quelle |
| **6 – Alarm und Countdown** | 2 | AlarmKit pro Timer, Countdown-Live-Activity, Aktionen | **Version 2 in TestFlight.** Alarm klingelt im Stummmodus, „Jetzt gewechselt“ funktioniert aus Alarm und Live Activity |
| **7 – Schnellzugriffe** | 3 | Kontrollzentrum, Siri/Kurzbefehle mit Snippets, CarPlay | **Version 3 in TestFlight** |

---

## 11. Tests

- **Unit-Tests (Swift Testing, auch unter Linux):** Timer-Status, Schwellenübernahme,
  Erinnerungsplan (Bündeln, Schlummern, Überfällig, Ruhezeiten, nur Zukünftiges),
  JSON-Dekodierung mit Beispielantworten von v3 als Fixtures, `history` mit gelöschten
  Einträgen, Warteschlange, Zusammenführen der Schlauch-Listen, Schlauch-Regel.
- **Integrationstests:** gegen einen lokalen Nightscout per Docker
  (`nightscout/cgm-remote-monitor` + MongoDB) auf dem Linux-Runner: Lesen, Eintragen,
  Wiederholung ohne Duplikat, Verhalten mit der Rolle `diabtimer` und mit `readable` +
  `careportal`, Löschen und Abgleich.
- **UI-Tests:** Einrichtung, Kombi-Dialog, Rückgängig.
- **Manuell auf echten Geräten über TestFlight:** Benachrichtigungs-Aktionen, Widgets,
  iCloud-Abgleich zwischen zwei Geräten (auch nach Offline-Phase), ab Version 2 AlarmKit im
  Stummmodus und mit Fokus sowie die Live Activity.

---

## 12. Risiken

| Risiko | Gegenmaßnahme |
|---|---|
| Token hat zu wenige Rechte | Einrichtung prüft `apiPermissions`, erklärt die Rolle `diabtimer` und blendet nicht erlaubte Funktionen aus |
| Wechsel aus einer anderen App, Erinnerung ist noch alt geplant | Hintergrund-Abgleich vor jeder Schwelle, „zuletzt abgeglichen“ in der Meldung, lauter Alarm standardmäßig aus |
| Hintergrund-Abgleich ist unzuverlässig | Erinnerungen sind lokal geplant und funktionieren trotzdem. Beim Öffnen der App wird sofort abgeglichen |
| AlarmKit oder Countdown verhalten sich anders als angenommen | Test am Gerät schon in Phase 0. Version 1 kommt ohne beides aus |
| Entwicklung ohne lokales Xcode ist langsam | Logik in Linux-testbaren Paketen, früher TestFlight-Build, Mac als Ausweg |
| iCloud nicht verfügbar oder andere Apple-ID | Schlauch-Timer funktioniert lokal weiter, iCloud-Status in den Einstellungen und auf der Karte |
| iCloud gleicht verzögert ab | Zusammenführen über IDs, kein Eintrag geht verloren |
| Versehentlicher Eintrag | Kein Eintrag verlässt das Gerät durch einen einzelnen Tipp (Abschnitt 4) |
| Geplanter Build wird von GitHub abgeschaltet | Auto-Build aktiviert sich selbst neu, Warnung bei altem TestFlight-Build |
| TestFlight-Builds laufen nach 90 Tagen ab | Monatlicher Build |
| Gemeinsames Zertifikat in `Match-Secrets` wird versehentlich widerrufen | Kein Nuke-Job und keine Nuke-Lane, schreibender Zugriff nur für die Profile von DiabTimer mit `force: false` |
| Gemeinsames Zertifikat oder API-Schlüssel läuft ab | Zentrale Erneuerung im Loop-Fork, danach Workflows 3 und 4 neu ausführen |
| Runner-Label `xcode-27` nicht verfügbar | Klärung im ersten Lauf, Ausweichen auf das aktuelle macOS-Image |
| Zeitzonen und Uhrumstellung | UTC intern, `utcOffset` beim Schreiben, eigene Testfälle |

---

## 13. Entscheidungen

| Thema | Entscheidung |
|---|---|
| App-Name, Repository | DiabTimer, `feebleeDIYorg/DiabTimer` (bisher `management-timer`) |
| Plattform | iOS, Mindestversion iOS 26 |
| Fokus | Wechsel-Timer |
| Nightscout | genau ein Server, neueste Version, nur API v3, Anmeldung nur per Token |
| Rechte | eigene Rolle `diabtimer`, Mindestvariante `readable` + `careportal` |
| Umfang | drei Versionen: Kern, Alarm und Countdown, Schnellzugriffe |
| Schlauch-Timer | iCloud-Schlüssel-Wert-Speicher statt CloudKit, nie Nightscout |
| Schlauch-Schwellen | 5 / 6 / 7 Tage (Warnung nach 6 Tagen) |
| „Schlauch auch gewechselt“ | an, wenn der Schlauch älter als 4 Tage ist (einstellbar, auch „immer“ und „nie“) |
| Schutz vor Fehleinträgen | App: 15 s Rückgängig. Widget: zwei Tipps. Sonst: Bestätigung |
| Erinnerungen | bündeln, täglich bei Überfälligkeit, „dringend“ vor die Ruhezeit vorziehen |
| Alarm | pro Timer einschaltbar, standardmäßig aus |
| Countdown-Vorlauf | 2 Stunden vor „dringend“ |
| Speicherung | JSON-Datei in der App Group, keine Datenbank |
| Projektdatei | XcodeGen |
| Entwicklung | alles über den Browser-Build, Mac nur als Ausweg |
| Verteilung | TestFlight, nur interne Tester |
| CI | Aufbau wie im Loop-Fork, ohne Upstream-Sync und ohne Nuke, Build bei neuen Commits über den Tag `testflight-latest` |
| Signierung | bestehendes Repo `feebleeDIYorg/Match-Secrets`, gemeinsames Zertifikat, eigene Profile |
| Bundle-IDs | Muster des Loop-Forks: `com.<TEAMID>.DiabTimer` |
| Secrets | bestehende Organisations-Secrets, für alle Repos freigegeben |

## 14. Offene Punkte

- **Repo umbenennen:** `feebleeDIYorg/management-timer` in `feebleeDIYorg/DiabTimer`
  (GitHub → Settings → General → Repository name).
- **Rolle und Token in Nightscout anlegen:** Rolle `diabtimer` mit den Rechten aus Abschnitt 3,
  dazu ein Subject mit dieser Rolle. Nötig ab Phase 1.
- **Ergebnisse aus Phase 0:** AlarmKit mit Countdown, iCloud-Speicher, Runner-Label.

Die Umsetzung beginnt mit Phase 0, sobald sie freigegeben ist.

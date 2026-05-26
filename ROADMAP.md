# Twitch Channel Points Miner — Multi-Account Orchestrator (Vision & Plan)

> Erweiterung des bestehenden Single-Account-Miners zu einem Docker-basierten Multi-Account-System mit Web-Oberfläche, automatischer MFA-Pipeline und koordinierter Wett-Strategie.

Dieses Dokument beschreibt das Zielsystem, die Architektur, das Datenmodell, den Lebenszyklus eines Accounts und den phasierten Umsetzungsplan. Es ist die Referenz für alle nachfolgenden Implementierungs-PRs.

---

## 1. Ziele

1. **Mehrere Twitch-Accounts** (`<10`) laufen parallel in einem Prozess innerhalb eines Docker-Containers, auf derselben Streamer-Liste.
2. **Web-Oberfläche** (Browser, lokal/im LAN erreichbar) zur Kontrolle:
   - Account-Verwaltung (hinzufügen, entfernen, pausieren) im **laufenden Betrieb** — Neustart nicht erforderlich.
   - Live-Status pro Account (eingeloggt? Punkte? aktuelle Wette? Online-Streamer?).
   - Manuelles Wett-Fan-out: eine Wette auf alle (oder ausgewählte) Accounts gleichzeitig auslösen.
   - Toggle „Auto-Bet aus" → autonome Wett-Engine pausiert, manuelle Wetten weiterhin möglich.
3. **Watchdog**: erkennt tote Sessions (abgelaufene Cookies, ungültige Tokens) und löst die Re-Auth-Pipeline aus, bevor Watch-Streaks verloren gehen.
4. **MFA-Automatisierung** über eigene Mailbox pro Account (`twitch+account-XYZ@rohner.dev`). Dreistufige Eskalation:
   - Stufe 1: Voll-automatisches Browser-Login + Code-Eintrag.
   - Stufe 2: Code aus Inbox extrahieren, Push/Mail mit Code + Activate-Link an Haupt-Inbox.
   - Stufe 3: Eskalierende Erinnerung „Re-Auth nötig" falls nicht innerhalb X Minuten reagiert.
5. **Koordinierte Wett-Strategie** über alle Accounts:
   - Feeder-Pyramide: kleine Accounts wetten gegeneinander, Sieger akkumulieren Punkte.
   - Champion-Feeder verwendet sein hohes Budget, um auf wahrscheinlich-verlierende Outcomes zu setzen → erhöht den Pott zugunsten des Haupt-Accounts.
   - Ziel: Haupt-Account ≥ 10 Mio Punkte pro Streamer.

---

## 2. Nicht-Ziele

- **Keine** Streaming-Funktionen (Chat-Bots, Mod-Aktionen, etc.) über das hinaus, was der bestehende Miner schon liefert.
- **Keine** Mobile App.
- **Keine** Cloud-/Multi-User-Plattform — System ist single-user, läuft im Heimnetz.
- **Keine** Wett-Strategie-Optimierung über die definierte Pyramide hinaus (kein ML, kein Backtesting-Framework).

---

## 3. High-Level-Architektur

```
┌───────────────────────────────────────────────────────────────────────┐
│                    Docker-Container: tcpm-orchestrator                │
│                                                                       │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐        │
│  │  Web-Server │◄──►│ Orchestrator│◄──►│  Account 1..N       │        │
│  │  :8080      │    │ (Supervisor)│    │  ├─ Miner (run)     │        │
│  │  REST + WS  │    │             │    │  ├─ Twitch-Client   │        │
│  │  Static UI  │    │             │    │  ├─ PubSub-Conn     │        │
│  └─────────────┘    └─────────────┘    │  └─ Chat-Watcher    │        │
│         ▲                  ▲           └─────────────────────┘        │
│         │                  │                     ▲                    │
│         │                  ▼                     │                    │
│         │           ┌─────────────┐              │                    │
│         │           │ Coordinator │──────────────┘                    │
│         │           │ (Pyramide,  │   Bet-Commands                    │
│         │           │  Auto-Bet)  │                                   │
│         │           └─────────────┘                                   │
│         │                  ▲                                          │
│         │                  │ Events                                   │
│         │           ┌──────┴──────┐                                   │
│         │           │  Event-Bus  │                                   │
│         │           └─────────────┘                                   │
│         │                                                             │
│         ▼                                                             │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐        │
│  │  Watchdog   │    │ MFA-Pipeline│    │  Mail-Reader (IMAP) │        │
│  │  (Liveness) │───►│ (3 Stages)  │◄───│   pro Alias         │        │
│  └─────────────┘    └─────────────┘    └─────────────────────┘        │
│                            │                                          │
│                            ▼                                          │
│                     ┌─────────────┐                                   │
│                     │  Notifier   │  SMTP + optional                  │
│                     │             │  Pushover/Discord                 │
│                     └─────────────┘                                   │
│                                                                       │
│  ┌─────────────────────────────────────────────────────────────┐      │
│  │  SQLite-DB (Volume-gemounted): Accounts, Settings,          │      │
│  │  Cookies, Bet-History, Pyramide-State, Audit-Log            │      │
│  └─────────────────────────────────────────────────────────────┘      │
│                                                                       │
└───────────────────────────────────────────────────────────────────────┘
              ▲                                          ▲
              │                                          │
       Browser (Du)                              Externer SMTP/IMAP
                                                 (Migadu/Fastmail)
```

**Designprinzipien**

- **Ein Prozess, ein Container.** Alle Services laufen als Goroutinen im selben Go-Binary. Vereinfacht Build, Deploy, Logging.
- **Persistenz in SQLite** (Volume gemounted). Keine externe Datenbank nötig.
- **Stateless Web-UI**: HTML/JS embedded ins Binary (`embed.FS`). Backend exponiert REST + WebSocket.
- **Hot-Reconfig**: Account-Liste, Settings, Auto-Bet-Toggle änderbar zur Laufzeit. Keine Restarts.

---

## 4. Komponenten im Detail

### 4.1 Orchestrator (Supervisor)

Verwaltet den Lebenszyklus aller Account-Worker.

**Verantwortung**

- Beim Start: alle Accounts aus DB laden, je einen `Account`-Worker spawnen.
- Auf REST-Calls hin: Account hinzufügen / entfernen / pausieren / fortsetzen.
- Schickt `context.Cancel` an Worker bei Stop. Wartet auf sauberes Beenden (Chat-Disconnect, PubSub-Close, Cookie-Save).
- Hält pro Account einen Status-Snapshot im Speicher (für `/accounts` API).

**Wichtige Datentypen** (geplant)

```go
type Account struct {
    ID          int64          // PK in DB
    Username    string
    EmailAlias  string         // twitch+xxx@rohner.dev
    Role        AccountRole    // MAIN | FEEDER | OBSERVER
    Settings    StreamerSettings // global default, per-streamer overrides separat
    LoginState  LoginState     // OK | EXPIRED | MFA_PENDING | LOCKED
    LastSeen    time.Time
    Paused      bool

    miner   *Miner            // läuft in eigener Goroutine
    cancel  context.CancelFunc
}

type Orchestrator struct {
    db        *sql.DB
    accounts  map[int64]*Account
    mu        sync.RWMutex
    bus       *EventBus
    coord     *Coordinator
}

func (o *Orchestrator) AddAccount(ctx context.Context, in AddAccountInput) (*Account, error)
func (o *Orchestrator) RemoveAccount(ctx context.Context, id int64) error
func (o *Orchestrator) PauseAccount(ctx context.Context, id int64) error
func (o *Orchestrator) ListAccounts() []*Account
```

### 4.2 Account-Worker (Miner-Erweiterung)

Pro Account läuft eine Instanz des bestehenden `Miner.run` — leicht refactored:

- Eigenes Cookie-Verzeichnis pro Account: `data/cookies/<account_id>.json` (statt `cookies/<username>.json`).
- Eigene Logger-Instanz mit Account-Prefix.
- Liest Toggle „Auto-Bet aus" aus dem `Coordinator` und überspringt `placePrediction`-Aufrufe, wenn aktiv (siehe §4.4).
- Sendet Events (`PointsChanged`, `PredictionStarted`, `BetPlaced`, etc.) in den Event-Bus.

### 4.3 Watchdog

Pollt jeden Account in regelmäßigem Intervall (konfigurierbar, Default 5 min). Verwendet einen billigen GQL-Call (z. B. `GetIDFromLogin` mit dem eigenen Username), der unter Token-Expiry sofort einen 401 liefert.

**Erkennung**

- Token expired / cookie missing → `LoginState = EXPIRED` → MFA-Pipeline triggern.
- HTTP-Fehler ≠ 401 → loggen, neuer Versuch beim nächsten Tick.
- Zwei aufeinanderfolgende Expired → eskalieren, Account `PAUSED` setzen bis Re-Auth abgeschlossen.

### 4.4 Coordinator + Auto-Bet-Toggle

Zentraler Punkt für **alle** Wett-Entscheidungen über Account-Grenzen hinweg.

**Aufgaben**

1. **Auto-Bet-Toggle**: Atomic `bool`. Web-UI setzt ihn. Bevor ein Account autonom wettet, fragt er beim Coordinator nach.
   - Toggle = `true` (Auto-Bet AN): Coordinator entscheidet pro Event, welche Accounts welche Outcome setzen (siehe Pyramide).
   - Toggle = `false` (Auto-Bet AUS): keine autonomen Wetten. Nur manuelle Fan-Out-Bets aus dem Web-UI gehen durch.
2. **Pyramide-State-Machine** (§5).
3. **Manuelles Fan-out**: Web-UI POSTet `{ event_id, outcome_idx, amount_per_account }` oder `{ amount_percent_balance }`. Coordinator fordert die ausgewählten Accounts auf, `MakePrediction` mit dem gegebenen Outcome auszuführen.

### 4.5 Event-Bus

In-process Pub/Sub (z. B. `chan` + Fan-out, oder eigene kleine Implementierung). Verbindet:

- Miner-Goroutinen (publish: Points-, Prediction-, Presence-Events)
- Coordinator (subscribe)
- Web-Server WS (subscribe → an Browser pushen)
- Audit-Logger (subscribe → DB schreiben)

### 4.6 MFA-Pipeline

Aktiviert durch Watchdog-Signal `LoginState = EXPIRED`. Drei Stufen, eskalierend:

#### Stufe 1 — Browser-Auto-Login (chromedp/rod)

1. Spawne headless Chromium.
2. Öffne `https://www.twitch.tv/activate`.
3. Falls nicht eingeloggt: Login-Form ausfüllen (Username + Password aus DB).
4. Falls reCAPTCHA / Bot-Check: scheitern, weiter zu Stufe 2.
5. Falls MFA-Code-Mail: parallel Mail-Reader anwerfen, Code holen, eintragen.
6. Device-Code-Bestätigung klicken.
7. Cookies in Jar extrahieren, speichern, Account auf `LoginState = OK` setzen.

Hohes Bot-Detection-Risiko, daher fallback auf Stufe 2 ohne langes Retry.

#### Stufe 2 — Code-Extract + Push

1. Mail-Reader liest pro Account die Mailbox `twitch+<id>@rohner.dev` via IMAP.
2. Filtert Mails von `noreply@twitch.tv` (oder ähnlich).
3. Extrahiert OTP-Code per Regex.
4. Schickt Notification (SMTP an Haupt-Inbox + optional Pushover/Discord) mit:
   - Account-Name
   - Code
   - Direktlink zu `https://www.twitch.tv/activate?device_code=...`
5. Wartet bis zu N Minuten (Default 5) auf erfolgreichen Token-Erhalt durch den parallel laufenden Device-Flow.

#### Stufe 3 — Eskalation

Nach Timeout in Stufe 2: zweite Erinnerung mit höherer Priorität (`!URGENT!` im Betreff, ggf. zweite Notification-Channel). Account bleibt `PAUSED`. Erst bei manueller Bestätigung über Web-UI wird der Versuch wiederholt.

### 4.7 Mail-Reader

- Verbindet sich mit IMAP-Server (`imap.<provider>.tld:993`, TLS).
- Pollt Inbox oder nutzt IMAP IDLE für Push.
- Filtert nach Empfänger-Adresse (`To:` enthält `twitch+<alias>@…`).
- Filtert nach Absender (`noreply@twitch.tv`).
- Extrahiert Code, schreibt in DB-Tabelle `mfa_codes (account_id, code, received_at, used)`.
- Markiert Mail als gelesen, optional verschiebt sie in `Processed`-Ordner.

### 4.8 Notifier

- SMTP-Client mit Anmeldung (App-Password / SMTP-Token).
- Templates für Stage-2- und Stage-3-Mails.
- Optional: Pushover/Discord-Webhook für Push-Benachrichtigungen.

### 4.9 Web-Server

- Bedient `:8080` (konfigurierbar). HTTP only intern; TLS optional via Reverse-Proxy.
- Statisches Frontend (HTML + Vanilla JS oder kleines Framework — Preact/Lit/Alpine.js — kein Build-Schritt nötig wenn möglich).
- REST + WebSocket. Detailspec siehe §7.

---

## 5. Wett-Strategie: Feeder-Pyramide

### 5.1 Account-Rollen

- **MAIN**: maximales Punkte-Ziel. Wettet immer **klein** auf das wahrscheinlich-gewinnende Outcome.
- **FEEDER**: Punkte-Akquise dient nur als Munition. Beteiligt sich an Pyramide.
- **OBSERVER**: mined nur passiv (Watch + Drops), wettet gar nicht. Backup-Bankroll.

### 5.2 Phasen einer Prediction

```
Event start
   │
   ▼
┌─────────────────────────┐
│ Phase A: Pre-Bet        │  Coordinator analysiert Outcome-Wahrscheinlichkeiten
│ (analyse)               │  via Strategie (z. B. SMART, MOST_VOTED)
└─────────────────────────┘
   │
   ▼
┌─────────────────────────┐
│ Phase B: Feeder-Battle  │  Bei Events mit ~50/50: Feeder werden aufgeteilt
│ (akkumuliere Champion)  │  und gegeneinander gesetzt.
└─────────────────────────┘
   │
   ▼
┌─────────────────────────┐
│ Phase C: Main-Boost     │  Champion-Feeder mit höchstem Saldo
│ (Champion vs Main)      │  setzt HOCH auf voraussichtlich verlierendes Outcome.
│                         │  Main setzt auf voraussichtlich gewinnendes Outcome.
└─────────────────────────┘
   │
   ▼
Event resolved → Coordinator schreibt Bet-History,
                 updated Pyramide-State (Rangliste der Feeder).
```

### 5.3 State-Machine

```go
type PyramidState struct {
    StreamerID  string
    Round       int                   // wie viele Battles bisher
    Standings   []FeederStanding      // Feeder sortiert nach Saldo, absteigend
    LastChampion int64                // letzter Feeder, der gegen Main spielte
}

type FeederStanding struct {
    AccountID int64
    Points    int
    WinStreak int  // wieviele Battles in Folge gewonnen
}
```

### 5.4 Entscheidungslogik (vereinfacht)

```
function decideForEvent(event, accounts):
    main = accounts.where(role=MAIN)
    feeders = accounts.where(role=FEEDER).sortByBalance(desc)

    if event.outcomeCount == 2 and event.percentSplit < gapThreshold:
        # Phase B: Feeder-Battle
        half = len(feeders) // 2
        for i in 0..half-1:
            schedule(feeders[i], outcome=0, amount=allIn(feeders[i]))
        for i in half..len(feeders)-1:
            schedule(feeders[i], outcome=1, amount=allIn(feeders[i]))

    elif feeders[0].balance > main.balance * boostThreshold:
        # Phase C: Main-Boost
        likelyWinner = pickByStrategy(event, "MOST_VOTED")
        likelyLoser  = 1 - likelyWinner
        schedule(feeders[0], outcome=likelyLoser, amount=feeders[0].balance * 0.9)
        schedule(main, outcome=likelyWinner, amount=main.balance * 0.01)

    else:
        # Phase A: nur Main wettet konservativ
        schedule(main, outcome=pickByStrategy(event), amount=safeAmount(main))
```

Parameter (`gapThreshold`, `boostThreshold`, etc.) sind pro Streamer konfigurierbar und persistiert in der DB.

### 5.5 Realitätscheck

Twitch verteilt den Pott proportional zur Stake-Höhe innerhalb der Gewinnerseite:

```
main_payout = main.stake / sum(winning_stakes) × total_pot
```

Damit die Pyramide Wirkung hat, müssen:
- Externe Wett-Teilnehmer am Stream wenig sein (kleinerer Streamer = besser).
- Champion-Feeder-Stake >> sonstige Stakes auf der Verlierer-Seite.
- Main-Stake << andere Stakes auf der Gewinner-Seite (Verdünnung minimieren).

Das System loggt nach jedem Event den tatsächlichen ROI und passt ggf. die Schwellen an

### 5.6 ToS-Hinweis

Multi-Account-Manipulation von Predictions verstößt gegen die Twitch-Nutzungsbedingungen. Ban-Risiko ist **real**, besonders für den Haupt-Account (Punkte können zurückgesetzt oder Account dauerhaft suspendiert werden). Das Feature wird gebaut, aber die Verantwortung liegt beim Nutzer.

---

## 6. Datenmodell (SQLite)

Tabellen (vereinfacht):

```sql
CREATE TABLE accounts (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    username        TEXT NOT NULL UNIQUE,
    password_enc    BLOB,             -- AES-encrypted, key from env
    email_alias     TEXT NOT NULL,    -- twitch+xxx@rohner.dev
    role            TEXT NOT NULL,    -- MAIN | FEEDER | OBSERVER
    paused          BOOLEAN DEFAULT 0,
    login_state     TEXT DEFAULT 'UNKNOWN',
    settings_json   TEXT,             -- StreamerSettings overrides
    created_at      DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE cookies (
    account_id      INTEGER PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
    jar_json        TEXT NOT NULL,
    saved_at        DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE streamers (
    name            TEXT PRIMARY KEY,
    settings_json   TEXT,             -- per-streamer overrides (global)
    enabled         BOOLEAN DEFAULT 1
);

CREATE TABLE account_streamer_settings (
    account_id      INTEGER REFERENCES accounts(id) ON DELETE CASCADE,
    streamer        TEXT REFERENCES streamers(name) ON DELETE CASCADE,
    settings_json   TEXT,
    PRIMARY KEY (account_id, streamer)
);

CREATE TABLE bet_history (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id      INTEGER REFERENCES accounts(id),
    streamer        TEXT,
    event_id        TEXT,
    placed_at       DATETIME,
    outcome_idx     INTEGER,
    amount          INTEGER,
    result          TEXT,             -- WIN | LOSE | REFUND | PENDING
    points_won      INTEGER,
    source          TEXT              -- AUTO_PYRAMID | MANUAL_FANOUT | MAIN_BOOST
);

CREATE TABLE pyramid_state (
    streamer        TEXT PRIMARY KEY,
    state_json      TEXT              -- serialized PyramidState
);

CREATE TABLE mfa_codes (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id      INTEGER REFERENCES accounts(id),
    code            TEXT,
    received_at     DATETIME,
    used            BOOLEAN DEFAULT 0
);

CREATE TABLE audit_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    at              DATETIME DEFAULT CURRENT_TIMESTAMP,
    account_id      INTEGER,
    kind            TEXT,             -- ADDED | REMOVED | PAUSED | RESUMED | RE_AUTH | BET | ...
    details_json    TEXT
);

CREATE TABLE settings_kv (
    key             TEXT PRIMARY KEY,
    value           TEXT
);
-- z. B. auto_bet_enabled=true, gap_threshold=20, boost_threshold=10, etc.
```

**Verschlüsselung**: Passwörter werden mit AES-GCM verschlüsselt. Key kommt aus `TCPM_ENC_KEY` (Env-Variable, im Docker-Compose-Secret). Ohne Key startet das Programm nicht.

---

## 7. API-Surface

REST + WebSocket. Alle Pfade unter `/api/v1`.

### 7.1 Accounts

| Methode | Pfad | Beschreibung |
|---|---|---|
| `GET` | `/api/v1/accounts` | Liste aller Accounts mit aktuellem Status |
| `POST` | `/api/v1/accounts` | Neuen Account anlegen (Body: username, password optional, role, email_alias) |
| `GET` | `/api/v1/accounts/{id}` | Detailansicht eines Accounts |
| `PATCH` | `/api/v1/accounts/{id}` | Felder ändern (role, paused, settings) |
| `DELETE` | `/api/v1/accounts/{id}` | Account stoppen + entfernen |
| `POST` | `/api/v1/accounts/{id}/pause` | Pausieren (Worker wird gestoppt, Daten bleiben) |
| `POST` | `/api/v1/accounts/{id}/resume` | Fortsetzen |
| `POST` | `/api/v1/accounts/{id}/reauth` | MFA-Pipeline manuell anstoßen |

### 7.2 Wetten

| Methode | Pfad | Beschreibung |
|---|---|---|
| `POST` | `/api/v1/bets/manual` | Manuelles Fan-out (Body: `event_id`, `outcome_idx`, `account_ids[]`, `amount` oder `amount_percent`) |
| `GET` | `/api/v1/bets?account_id=…` | Bet-History pro Account |
| `GET` | `/api/v1/predictions/active` | aktuell laufende Prediction-Events über alle Accounts |

### 7.3 Settings

| Methode | Pfad | Beschreibung |
|---|---|---|
| `GET` | `/api/v1/settings` | globale Settings (Auto-Bet-Toggle, Schwellen, etc.) |
| `PATCH` | `/api/v1/settings` | partial update |
| `POST` | `/api/v1/settings/auto-bet/toggle` | Schalter umlegen, idempotent (`{enabled: true/false}`) |
| `GET` | `/api/v1/streamers` | Streamer-Liste |
| `POST` | `/api/v1/streamers` | Streamer hinzufügen |
| `DELETE` | `/api/v1/streamers/{name}` | Streamer entfernen |

### 7.4 Live-Stream

| Methode | Pfad | Beschreibung |
|---|---|---|
| `GET` | `/ws/events` | WebSocket. Server pusht alle Events (Points, Bet placed, Prediction started, Re-Auth needed, …). |

### 7.5 Health / Ops

| Methode | Pfad | Beschreibung |
|---|---|---|
| `GET` | `/healthz` | Liveness (200 wenn Hauptloop läuft) |
| `GET` | `/readyz` | Readiness (200 wenn DB erreichbar + mindestens 1 Account gestartet) |
| `GET` | `/metrics` | Prometheus-Format (optional) |

---

## 8. Account-Lebenszyklus

```
                 POST /accounts
                      │
                      ▼
              ┌───────────────┐
              │ DB-Insert     │
              │ row created   │
              └───────────────┘
                      │
                      ▼
              ┌───────────────┐
              │ Worker spawn  │  Orchestrator.AddAccount triggert
              │ (goroutine)   │  → context per Account
              └───────────────┘
                      │
                      ▼
              ┌───────────────┐    Cookies vorhanden + Token gültig?
              │ Login-Check   ├─── ja ──► state=OK ─► Mining startet
              └───┬───────────┘
                  │ nein
                  ▼
              ┌───────────────┐
              │ MFA-Pipeline  │  Stufe 1 → 2 → 3 (siehe §4.6)
              └───┬───────────┘
                  │ Erfolg
                  ▼
              ┌───────────────┐
              │ Cookies save  │
              │ state=OK      │
              └───┬───────────┘
                  │
                  ▼
              ┌───────────────┐
              │ Running       │◄─── Watchdog tickt alle 5 min
              └───┬───────────┘
                  │
                  ├─── /pause oder Auto-Eskalation ──► state=PAUSED
                  │
                  └─── /delete ──► state=STOPPED → DB-Delete
```

**Wichtig:** Beim Spawnen eines Account-Workers werden Streamer aus der globalen Liste übernommen. Streamer-Add (über Web-UI) propagiert an alle laufenden Worker, ohne diese neu zu starten.

---

## 9. Docker-Setup

### 9.1 Dockerfile (Multi-Stage)

```dockerfile
# ----- build -----
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=1 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/tcpm .
# CGO=1 wegen sqlite (modernc.org/sqlite wäre CGO-frei, prüfen)

# ----- runtime -----
FROM alpine:3.20
RUN apk add --no-cache ca-certificates chromium tzdata
# chromium für Stufe-1-MFA (chromedp nutzt headless chromium)
WORKDIR /app
COPY --from=build /out/tcpm /app/tcpm
COPY web/ /app/web/   # falls Static Assets nicht embedded
EXPOSE 8080
VOLUME ["/data"]
ENV TCPM_DATA_DIR=/data
ENTRYPOINT ["/app/tcpm"]
```

### 9.2 docker-compose.yml

```yaml
services:
  tcpm:
    build: .
    image: tcpm:latest
    container_name: tcpm
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - tcpm-data:/data
    environment:
      TZ: "Europe/Berlin"
      TCPM_DATA_DIR: "/data"
      TCPM_ENC_KEY_FILE: "/run/secrets/enc_key"
      TCPM_SMTP_HOST: "smtp.migadu.com"
      TCPM_SMTP_PORT: "587"
      TCPM_SMTP_USER: "twitch@rohner.dev"
      TCPM_SMTP_PASS_FILE: "/run/secrets/smtp_pass"
      TCPM_IMAP_HOST: "imap.migadu.com"
      TCPM_IMAP_USER: "twitch@rohner.dev"
      TCPM_IMAP_PASS_FILE: "/run/secrets/imap_pass"
      TCPM_NOTIFY_TO: "jamie@rohner.dev"
    secrets:
      - enc_key
      - smtp_pass
      - imap_pass

volumes:
  tcpm-data:

secrets:
  enc_key:
    file: ./secrets/enc_key
  smtp_pass:
    file: ./secrets/smtp_pass
  imap_pass:
    file: ./secrets/imap_pass
```

**Volume-Layout** (`/data` im Container):

```
/data
├── tcpm.sqlite              # Hauptdatenbank
├── tcpm.sqlite-wal
├── tcpm.sqlite-shm
├── log/
│   └── tcpm.log
└── chromium-profile/        # persistente Browser-Sessions für Stufe-1-MFA
```

### 9.3 Mail-Infrastruktur

**Außerhalb** des Containers. Optionen:

- **Migadu** (empfohlen, einfach, Catch-All inkl., ~5€/mo).
- **Fastmail** (Catch-All ja, etwas teurer).
- **Self-host** (mailcow/mail-in-a-box) — mehr Kontrolle, mehr Aufwand.

Setup für `rohner.dev`:

1. MX-Record auf Provider zeigen.
2. Catch-All-Alias: alles an `twitch+*@rohner.dev` → ein einzelnes Postfach `twitch@rohner.dev`.
3. IMAP-Zugang mit App-Password.
4. Optional SPF/DKIM/DMARC für ausgehende Mail (Notifier).

### 9.4 Build- und Run-Befehle

```bash
# erstmal Secrets generieren
openssl rand -base64 32 > secrets/enc_key
echo "<smtp-app-password>" > secrets/smtp_pass
echo "<imap-app-password>" > secrets/imap_pass
chmod 600 secrets/*

# Build + Start
docker compose up -d --build

# Logs
docker compose logs -f tcpm

# Backup DB
docker compose exec tcpm sqlite3 /data/tcpm.sqlite ".backup '/data/backup-$(date +%F).sqlite'"
```

---

## 10. Web-UI

### 10.1 Stack

- **HTML/CSS/JS embedded** ins Binary mittels `embed.FS`. Kein separater Frontend-Build.
- **Vanilla JS** oder **Alpine.js** (kein Bundler, kein npm). Server liefert reines HTML + ein paar JS-Snippets.
- **WebSocket** für Live-Updates.

### 10.2 Seiten (Routen)

| Pfad | Inhalt |
|---|---|
| `/` | Dashboard: Account-Tabelle (Status, Punkte total, aktive Wetten) + Auto-Bet-Toggle |
| `/accounts/new` | Form: Account anlegen (Username, Passwort, Email-Alias, Rolle) |
| `/accounts/{id}` | Detailseite: Verlauf, Streamer-Settings, manuelle Re-Auth |
| `/predictions` | aktuelle Prediction-Events, manuelles Fan-out |
| `/streamers` | Streamer-Verwaltung |
| `/settings` | globale Settings (Schwellen, Mail-Empfänger, Watchdog-Intervall) |
| `/log` | Audit-Log (letzte 200 Einträge, mit Filter) |

### 10.3 Dashboard-Skizze

```
┌────────────────────────────────────────────────────────────────┐
│ TCPM Orchestrator                  [Auto-Bet: ●ON  /  ○OFF]    │
├────────────────────────────────────────────────────────────────┤
│ Accounts                                                       │
│ ┌─────────┬────────┬──────┬───────────┬──────────┬───────────┐ │
│ │ Name    │ Rolle  │ Login│ Streamer  │ Punkte   │ Aktionen  │ │
│ ├─────────┼────────┼──────┼───────────┼──────────┼───────────┤ │
│ │ main    │ MAIN   │ ✅ OK│ aaa,bbb…  │ 4.2M     │ ⏸ 🔁 🗑   │ │
│ │ feed1   │ FEEDER │ ⚠ MFA│ aaa,bbb…  │ 12k      │ ⏸ 🔁 🗑   │ │
│ │ feed2   │ FEEDER │ ✅ OK│ aaa,bbb…  │ 88k      │ ⏸ 🔁 🗑   │ │
│ └─────────┴────────┴──────┴───────────┴──────────┴───────────┘ │
│                                            [+ Account anlegen] │
├────────────────────────────────────────────────────────────────┤
│ Aktuelle Predictions                                           │
│ Streamer X: "Wer gewinnt Match 1?"  [BLAU 65% | ROT 35%]       │
│   Phase: B (Feeder-Battle)   [Manuell wetten →]                │
└────────────────────────────────────────────────────────────────┘
```

### 10.4 Manuelles Wetten

Dialog auf `/predictions`:

```
Event: "Wer gewinnt Match 1?"
Outcomes:  ○ BLAU (65%)   ● ROT (35%)

Accounts:  [✓] main    [✓] feed1   [✓] feed2   [ ] feed3

Stake:     ○ Fester Betrag:   [______]
           ● Prozent Saldo:   [___5_] %

[Wette platzieren]   [Abbrechen]
```

Klick → `POST /api/v1/bets/manual` → Coordinator fängt Auto-Bet-Pyramide ab, leitet die Wette pro Account direkt an `MakePrediction`.

---

## 11. Konfigurationsquellen

Drei Ebenen, jeweils mit Override:

1. **Env-Variablen** (Container-Level): SMTP-/IMAP-Zugang, Encryption-Key, Datenverzeichnis, Port.
2. **DB-Settings** (`settings_kv`): Auto-Bet-Toggle, Schwellen, Watchdog-Intervall, Notification-Empfänger.
3. **Account-/Streamer-Settings** (`accounts.settings_json`, `account_streamer_settings`): wie der heutige `streamer_overrides`-Block, aber pro Account und pro Streamer.

Es gibt **keine** `config.json` mehr für Account-Daten — alles über DB. Globales `config.json` bleibt nur für Bootstrapping (Default-Settings beim ersten Start).

---

## 12. Sicherheitsüberlegungen

- **Web-UI ohne Auth-Layer von Haus aus** — nur Loopback / LAN. Wer das im Internet exponiert, muss vor einen Auth-Proxy (Authelia, Caddy Basic-Auth, Cloudflare Access).
- **Passwörter in DB AES-verschlüsselt** mit Key aus Env-File (Docker-Secret).
- **Cookie-Jar in DB** (nicht Filesystem) — verhindert versehentliches Committen.
- **Audit-Log** für alle bet/auth-Aktionen, damit nachvollziehbar wenn Twitch bant.
- **Rate-Limits respektieren**: keine API-Calls häufiger als der bestehende Miner (Watchdog 5 min, Drop-Claimer 30 min, Context-Refresh 20 min).
- **Bot-Detection-Risiko** bei Stufe-1-MFA: chromedp-Profil persistieren (`/data/chromium-profile`), User-Agent + Fingerprint stabil halten, kein Headless-Mode-Flag.

---

## 13. Phasierter Umsetzungsplan

Jede Phase ist ein PR. Ergebnis muss funktionierend mergebar sein.

### Phase 0 — Multi-Account-Refactor (Pflichtbasis)

- [ ] `internal/db/`: SQLite-Layer (modernc.org/sqlite, CGO-frei), Migrations.
- [ ] `internal/account/`: `Account`-Struct + `Orchestrator`.
- [ ] `TwitchLogin` umbauen: Cookie-Persistenz über Storage-Interface (DB statt Datei).
- [ ] `Miner` umbauen: nimmt `context.Context` für Cancel, kein `os.Exit` mehr.
- [ ] `main.go`: bootstrapt Orchestrator statt einzelnen Miner.
- [ ] Tests: `OrchestratorAddRemove`, `AccountLifecycle`.

### Phase 1 — Web-Server + Auto-Bet-Toggle

- [ ] `internal/web/`: HTTP-Router (`net/http` + chi), `embed.FS` für Frontend.
- [ ] Endpoints: `GET /accounts`, `POST /accounts`, `DELETE /accounts/{id}`, `POST /pause`, `POST /resume`.
- [ ] Endpoint: `POST /settings/auto-bet/toggle`. Atomic-Flag im Coordinator.
- [ ] Frontend: Dashboard-HTML mit Account-Tabelle + Toggle (statisch, JS-Refresh per 5s Polling vorerst).
- [ ] Miner liest Toggle vor `placePrediction`.

### Phase 2 — Watchdog + Notifier

- [ ] `internal/watchdog/`: Liveness-Goroutine pro Account.
- [ ] `internal/notify/`: SMTP-Sender, Templates.
- [ ] Mail bei `LoginState=EXPIRED`.
- [ ] Web-UI: Spalte "Login-Status".

### Phase 3 — Docker-Setup

- [ ] `Dockerfile` (Multi-Stage).
- [ ] `docker-compose.yml`.
- [ ] Secret-Handling.
- [ ] CI: Image-Build im GitHub-Action-Workflow.

### Phase 4 — Mail-Reader + MFA-Stufe-2

- [ ] `internal/mail/`: IMAP-Client (`emersion/go-imap`).
- [ ] Code-Extract per Regex.
- [ ] Stage-2-Notification mit Code + Activate-Link.
- [ ] Integration in MFA-Pipeline.

### Phase 5 — Hot-Add Accounts + WebSocket-Live-Updates

- [ ] `POST /accounts` startet Worker zur Laufzeit.
- [ ] `/ws/events` pusht Updates statt Polling.
- [ ] Frontend: Live-Status ohne Reload.

### Phase 6 — Manuelles Fan-out

- [ ] `POST /bets/manual`.
- [ ] `/predictions`-Seite mit Outcome-Auswahl + Account-Multi-Select.
- [ ] Coordinator-Hook: manuelle Wette übersteuert Pyramide.

### Phase 7 — Coordinator + Pyramide

- [ ] `internal/coordinator/`: Event-Bus, Pyramide-State-Machine.
- [ ] DB-Persistenz für `pyramid_state`.
- [ ] Streamer-spezifische Schwellen über UI editierbar.
- [ ] Audit-Log für jede Pyramide-Entscheidung.

### Phase 8 — MFA-Stufe-1 (Browser-Auto-Login)

- [ ] `chromedp` integrieren.
- [ ] Chromium-Profil persistieren.
- [ ] Fallback auf Stufe 2 bei Bot-Detection.

### Phase 9 — Polishing

- [ ] Streamer-Hot-Add/Remove über UI.
- [ ] Audit-Log-Viewer.
- [ ] Backup-Job für SQLite.
- [ ] Prometheus-Metriken.

**Geschätzter Aufwand**: Phase 0–3 ~2 Wochen Vollzeit. Phase 4–9 nochmal ~3–4 Wochen. Realistisch verteilt auf mehrere Monate Hobbyprojekt.

---

## 14. Offene Fragen für späteres Refinement

Diese Punkte sind im aktuellen Stand bewusst offen. Vor Phase 7/8 müssen sie geklärt werden.

1. **Browser-Auto-Login**: chromedp vs. Playwright-Go vs. echtes Chrome-Profil mit User-Manual-Fallback? Bot-Detection-Heuristiken testen.
2. **Pyramide-Schwellen**: Default-Werte für `gapThreshold`, `boostThreshold`. Mit echten Streamer-Daten kalibrieren (Phase 7).
3. **Mail-Provider**: Migadu-Setup dokumentieren oder Self-host?
4. **Frontend-Framework**: Vanilla bleibt? Oder Alpine.js? Falls die UI komplex wird, evtl. später ein leichtgewichtiges Build-Tool.
5. **Authentifizierung Web-UI**: Plain HTTP im LAN OK, oder gleich Basic-Auth einbauen?
6. **Multi-Streamer-Pyramide**: parallel mehrere Streamer mit eigenen Pyramide-States — wie viel Bankroll wird pro Streamer reserviert?
7. **Account-Recovery bei DB-Loss**: Backup-Strategie + Recovery-Test.
8. **GDPR/Privacy**: lokale Personendaten (Passwörter, Mailadressen) — keine externen Sharing-Pfade.

---

## 15. Glossar

| Begriff | Bedeutung |
|---|---|
| **Main** | Haupt-Account, Ziel: ≥10M Punkte pro Streamer |
| **Feeder** | Hilfs-Account, dient nur als Wett-Munition für Main |
| **Observer** | Hilfs-Account ohne Wett-Beteiligung, sammelt nur Punkte |
| **Champion-Feeder** | Feeder mit aktuell höchstem Saldo, „Frontmann" gegen Main |
| **Pyramide** | sukzessive Konsolidierung der Feeder-Salden durch interne Battles |
| **Phase A/B/C** | Pre-Bet, Feeder-Battle, Main-Boost |
| **Stufe 1/2/3** | MFA-Eskalation: Auto-Login / Code-Push / Reminder |
| **Auto-Bet-Toggle** | globaler Schalter zur Pausierung der autonomen Wett-Engine |
| **Fan-out** | dieselbe Wette über mehrere Accounts in einem Request |
| **Hot-Add** | neuer Account ohne Programm-Restart angelegt + gestartet |

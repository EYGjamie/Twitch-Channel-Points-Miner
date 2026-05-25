# Twitch Channel Points Miner — Developer Notes

Go port of the Python miner. Single binary, no daemon. Targets Linux/macOS/Windows.

Version constant: `TwitchChannelPointsMiner/constants/constants.go` (`Version = "1.1"`).

## 1. Run / Build

```sh
go build .                 # binary in repo root
./Twitch-Channel-Points-Miner
```

Flags / env:

- `-config <path>` — explicit config.json path
- `-data-dir <dir>` — directory holding `config.json`, `cookies/`, `log/`
- `TCPM_CONFIG` / `TCPM_DATA_DIR` — same as flags
- No flag/env + `config.json` in CWD → CWD used; else exe directory used; else falls back to `os.UserConfigDir()/TwitchChannelPointsMiner` (when CWD is read-only, e.g. macOS quarantined binary).

Tests: `go test ./...`. Suites cover miner-picker, prediction, pubsub, chat, anonymizer, logger, constants, stream, types.

## 2. Process Topology

`main()` in [main.go](main.go) wires:

1. `resolveAppPaths` → workdir + config path
2. `loadOrCreateConfig` → fills missing keys with `defaultConfig()` defaults, persists, re-decodes into typed `config`
3. `RunAutoUpdate` (optional) — GitHub releases poll, atomic exe swap + relaunch; Windows uses .bat trampoline
4. `buildBaseStreamerSettings` + `buildOverrideSettings` → effective per-streamer settings
5. `miner.NewMiner(...)` + `Mine(...)` or `MineFollowers(DESC)`

`(*Miner).run` (in [TwitchChannelPointsMiner/miner.go](TwitchChannelPointsMiner/miner.go)) spawns 4 goroutines and blocks on SIGINT/SIGTERM:

| Goroutine | Cadence | Job |
|---|---|---|
| `dropClaimer` | 30 min | scan inventory, claim drops |
| `contextRefresher` | 20 min | reload channel-points context per streamer |
| `minuteWatcher` | continuous | pick ≤2 streamers, send minute-watched ping |
| `startPubSub` → `PubSubClient.run` (per batch of 50 topics) | reconnect loop | websocket: points, raids, predictions, moments, community goals, video-playback |

Shutdown path: `m.shutdown` closes `m.stop`, prints totals, stops chat watchers, `os.Exit(0)`.

## 3. Module Map

| Path | What |
|---|---|
| [main.go](main.go) | entry point, config loader, path resolution, merge logic |
| [TwitchChannelPointsMiner/miner.go](TwitchChannelPointsMiner/miner.go) | Miner core, watch-priority engine, point delta logging |
| [TwitchChannelPointsMiner/updater.go](TwitchChannelPointsMiner/updater.go) | self-update from GitHub releases |
| [TwitchChannelPointsMiner/logger.go](TwitchChannelPointsMiner/logger.go) | console + file logger, emoji + ANSI, Discord forwarder |
| [TwitchChannelPointsMiner/discord.go](TwitchChannelPointsMiner/discord.go) | webhook POST, event-filter |
| [TwitchChannelPointsMiner/classes/twitch.go](TwitchChannelPointsMiner/classes/twitch.go) | GraphQL client, drops/bonus claim, prediction submit, community-goals |
| [TwitchChannelPointsMiner/classes/twitch_login.go](TwitchChannelPointsMiner/classes/twitch_login.go) | OAuth device-code flow, cookie persistence |
| [TwitchChannelPointsMiner/classes/twitch_gql_types.go](TwitchChannelPointsMiner/classes/twitch_gql_types.go) | typed GQL response structs + helpers |
| [TwitchChannelPointsMiner/classes/pubsub.go](TwitchChannelPointsMiner/classes/pubsub.go) | websocket client, topic dispatch, prediction scheduling |
| [TwitchChannelPointsMiner/classes/prediction.go](TwitchChannelPointsMiner/classes/prediction.go) | bet strategies, outcome scoring, result parsing |
| [TwitchChannelPointsMiner/classes/chat.go](TwitchChannelPointsMiner/classes/chat.go) | IRC PRIVMSG presence watcher (no send) |
| [TwitchChannelPointsMiner/classes/entities/types.go](TwitchChannelPointsMiner/classes/entities/types.go) | shared structs + enums + defaults |
| [TwitchChannelPointsMiner/classes/entities/stream.go](TwitchChannelPointsMiner/classes/entities/stream.go) | stream metadata + minute-watched payload encoder |
| [TwitchChannelPointsMiner/classes/entities/community_goal.go](TwitchChannelPointsMiner/classes/entities/community_goal.go) | community-goal entity + GQL/PubSub parsers |
| [TwitchChannelPointsMiner/constants/constants.go](TwitchChannelPointsMiner/constants/constants.go) | URLs, client id, persisted GQL ops, version |
| [TwitchChannelPointsMiner/constants/events.go](TwitchChannelPointsMiner/constants/events.go) | event enum + name normalization |
| [TwitchChannelPointsMiner/privacy/anonymizer.go](TwitchChannelPointsMiner/privacy/anonymizer.go) | streamer alias + pseudo-points |
| [TwitchChannelPointsMiner/utils/utils.go](TwitchChannelPointsMiner/utils/utils.go) | JSON save helper |
| [TwitchChannelPointsMiner/utils/user_agents.go](TwitchChannelPointsMiner/utils/user_agents.go) | UA constants |

## 4. Key Functions to Know

- `(*Miner).pickStreamersToWatch` [miner.go:576](TwitchChannelPointsMiner/miner.go#L576) — selects up to `maxConcurrentWatchers = 2` streamers per pass. Honors `watchPriority` list (`STREAK`/`DROPS`/`ORDER`/`SUBSCRIBED`/`POINTS_ASC`/`POINTS_DESC`) plus `game_priority`/`game_exclude` filters. Forces a streak slot if a `WatchStreakMissing` streamer is eligible.
- `(*Miner).streakPriorityLimit` [miner.go:874](TwitchChannelPointsMiner/miner.go#L874) — bumps 7 min → 20 min after 10h uptime to reduce late-session churn.
- `(*Twitch).SendMinuteWatched` [classes/twitch.go:591](TwitchChannelPointsMiner/classes/twitch.go#L591) — refresh stream meta, fetch spade URL (cached on `Stream`), encode base64 payload, POST as `x-www-form-urlencoded`.
- `(*Twitch).LoadChannelPointsContext` [classes/twitch.go:322](TwitchChannelPointsMiner/classes/twitch.go#L322) — pulls balance + active multipliers + pending bonus claim + community goals, auto-claims the bonus when found.
- `(*PubSubClient).Start` [classes/pubsub.go:116](TwitchChannelPointsMiner/classes/pubsub.go#L116) — chunks topics into 50/batch, one goroutine per WS connection, 4-worker fan-out for message decode.
- `(*PubSubClient).processPredictionChannel` [classes/pubsub.go:616](TwitchChannelPointsMiner/classes/pubsub.go#L616) — schedules `placePrediction` via `time.AfterFunc(event.ClosingAfter(now))`; respects `delay_mode`.
- `(*PredictionEvent).Decide` [classes/prediction.go:122](TwitchChannelPointsMiner/classes/prediction.go#L122) — strategy + percentage + max/min + stealth-mode bet sizing. Forces ≥10 (Twitch minimum) when balance allows.
- `selectOutcome` [classes/prediction.go:376](TwitchChannelPointsMiner/classes/prediction.go#L376) — implements `SMART`/`MOST_VOTED`/`HIGH_ODDS`/`PERCENTAGE`/`SMART_MONEY`/`NUMBER_*` strategies.
- `(*TwitchLogin).Login` [classes/twitch_login.go:58](TwitchChannelPointsMiner/classes/twitch_login.go#L58) — try cached cookie file → fall back to device-code OAuth. Persists `auth-token` + `persistent` to `cookies/<username>.json` (mode 0600).
- `Anonymizer.Name` / `StreamerName` / `PseudoChannelPoints` [privacy/anonymizer.go](TwitchChannelPointsMiner/privacy/anonymizer.go) — `Streamer1`/`Streamer2`/… aliases and shifted-by-delta pseudo balances when `privacy.anonymize_logs=true`.
- `constants.ClonePersistedOperation` [constants/constants.go:38](TwitchChannelPointsMiner/constants/constants.go#L38) — **must** be used before mutating `Variables` so global persisted-op map stays immutable.

## 5. Config Surface (config.json)

Top-level keys (defaults filled in by `defaultConfig`):

```
username, password (optional, device-code flow if absent),
auto_update, debug, debug_deep,
watch_queue_logging, smart_logging, disable_ssl_cert_verification,
show_seconds, claim_drops_startup, claim_drops,
betting(make_predictions), follow_raid, community_goals,
emojis, save_logs, show_username_in_console,
show_claimed_bonus_msg, show_game, chat_presence (ONLINE/OFFLINE/ALWAYS/NEVER),
timezone (IANA, "auto" or null → system),
streamers[], streamers_exclude[],
game_priority[], game_exclude[],
watch_priority[] (default STREAK,DROPS,ORDER),
streamer_overrides{ <login>: { ...streamerSettings, bet:{...} } },
bet{ strategy, percentage, percentage_gap, max_points, minimum_points,
     stealth_mode, deduct_stake_on_place, delay_mode, delay,
     filter_condition{ by, where, value } },
privacy{ anonymize_logs },
discord{ webhook_api, events[] }
```

Per-streamer overrides merge atop the global `bet` block via `mergeBetSettings` / `mergeStreamerSettings`. Pointer-typed fields (`*int`/`*bool`) distinguish "unset" from zero.

Cookies live next to config in `cookies/<username>.json`. Logs in `log/<sanitized>.log` when `save_logs=true`.

## 6. Concurrency Model

- Per-streamer state lives in `*entities.Streamer`. `ChannelPoints`, `CommunityGoals`, `ActiveMultipliers`, `LastRaidID`, `History`, `Stream.*` are **mutated concurrently** by:
  - `contextRefresher` (poll)
  - PubSub workers (`processPointsEarned`, `processCommunityPointChannel`, `processClaimAvailable`, `processPlaybackMessage`)
  - `minuteWatcher` (via `SendMinuteWatched` → `UpdateStream`)
  - `placePrediction` (subtract stake)
- No mutex guards the streamer. **Race detector (`go test -race`) will flag many writes.** Currently masked because most writes update independent fields; rare interleavings can drop a points-earned or corrupt `History`.
- Predictions map is guarded by `predMu`. Chat watchers map by `chatMu`. Login token by `TwitchLogin.mu`.
- `time.AfterFunc` callbacks in `processPredictionChannel` outlive the connection; `placePrediction` re-reads from `predictions` map so cancellation is implicit.

## 7. Auto-Update Notes

- Detects "go run" by exe path containing `go-build` or living under temp; in that case logs and skips swap (no replace).
- macOS asset names: `TwitchChannelPointsMiner-darwin-<arch>`, `…-macos-<arch>`, `…-osx-<arch>`.
- Windows uses a generated `update-<nano>.bat` to move the new exe over the running one then self-deletes.
- Version compare is dotted-int; non-numeric suffixes stripped by `normalizeVersion`.

## 8. Bugs / Crash Risks

Legend: `[FIXED]` patched in tree · `[OPEN]` known issue not yet patched.

### B1. `applyTimezoneOverride` sets `time.Local = nil` on invalid zone — PANIC `[FIXED]`

[main.go:489](main.go#L489) — added `return` on `time.LoadLocation` error so `time.Local` retains the system default. Without the return, any subsequent `time.Now()`/format call nil-derefs.

### B2. Unchecked type assertions in `GetFollowers` — PANIC `[FIXED]`

[classes/twitch.go:299-321](TwitchChannelPointsMiner/classes/twitch.go#L299) — switched both casts to comma-ok form. `break` out of the cursor loop if `data.user.follows` is not an object; `continue` over edges that aren't maps. Miner now degrades to "no followers" instead of crashing if Twitch returns a non-canonical envelope.

### B3. Unchecked type assertions in `CampaignIDsForStreamer` + `inventory` — PANIC `[FIXED]`

[classes/twitch.go:1019-1034](TwitchChannelPointsMiner/classes/twitch.go#L1019) and [classes/twitch.go:1058-1063](TwitchChannelPointsMiner/classes/twitch.go#L1058) — comma-ok casts; returns empty list / nil instead of panicking when shape unexpected.

### B4. Data race on `streamer.ChannelPoints` `[OPEN — deferred, invasive]`

Concurrent `+=`/`-=` from PubSub workers + `placePrediction` + `ContributeToCommunityGoal` + `LoadChannelPointsContext`. Not auto-fixed: requires either a `sync.Mutex` per `Streamer` (touches ~30 read/write sites and risks deadlocking the HTTP path) or funneling all mutations through a single goroutine (bigger refactor). Run `go test -race` before fixing to baseline current race count.

### B5. `chunkTopics` with empty input `[FIXED — defensive]`

[classes/pubsub.go:878-895](TwitchChannelPointsMiner/classes/pubsub.go#L878) — added `len(topics)==0 → nil` guard so empty-topic callers can't spawn an idle reconnect loop. Unreachable today (`chunkSize=50` hardcoded, `buildTopics` always adds the user topic), but cheap insurance.

### B6. PubSub fatal at startup leaks chat goroutines `[OPEN — cosmetic]`

`m.twitch.Login` → `Fatalf` → `os.Exit` skips `stopAllChatWatchers`. Process exit cleans up sockets, no real damage. Worth replacing `Fatalf` with `return` + `m.shutdown` if you want clean teardown for embedded use.

### B7. Discord webhook blocks the log path `[FIXED]`

[discord.go:64-72](TwitchChannelPointsMiner/discord.go#L64) — wrapped `client.Do` + body close in a goroutine. Webhook is fire-and-forget; PubSub workers no longer stall up to 5 s when Discord is slow.

### B8. Cookie load may accumulate duplicates `[OPEN — risky]`

[classes/twitch_login.go:270](TwitchChannelPointsMiner/classes/twitch_login.go#L270) appends new cookies onto existing jar contents under repeated calls. cookiejar is internally synchronized so no panic, but duplicate `auth-token` entries can grow request headers. Not fixed automatically because dedup logic could mis-replay a stale token and break login. Manual fix: walk the existing jar, replace by name.

### B9. ~~`Decide` exceeds `MaxPoints`~~ `[INVALID — earlier analysis wrong]`

Re-checked: when `MaxPoints<10`, the floor branch sets `amount=MaxPoints` (≤9), not 10. When `MaxPoints≥10`, the bump to 10 is within cap. Not a bug. Leaving the note so future readers don't re-trip the same suspicion. Real residual oddity: stealth-mode may be undone by the floor bump (rare, low impact).

### B10. `pickAsset` case sensitivity `[OPEN — cosmetic]`

[updater.go:118-124](TwitchChannelPointsMiner/updater.go#L118) — `EqualFold` matches loosely; downstream rename is byte-for-byte. Foot-gun only if release asset names drift in case.

### B11. `processClaimAvailable` ignores missing channel ID `[OPEN — behavior change]`

[classes/pubsub.go:594](TwitchChannelPointsMiner/classes/pubsub.go#L594) — pending bonus then waits up to 5 h for `pollPendingClaims`. Not auto-fixed because guessing the channel can credit the wrong streamer.

## 9. Adding a Feature — Checklist

1. Add config field to both `config` struct ([main.go](main.go)) and `defaultConfig()` map literal.
2. Mirror per-streamer override in `streamerSettingsConfig` + `mergeStreamerSettings` if it should be overrideable.
3. Plumb through `NewMiner(...)` signature (callers: `main()`, tests in `miner_test.go`).
4. If it triggers Twitch GQL, add `GQLPersistedOperation` to `constants/constants.go` with the SHA256 from the current web client.
5. Add an `Event` constant + `EventFromGainReason`/`NormalizeEventName` mapping if you want Discord forwarding.
6. Wire through `Logger.EmojiEventf` (not `Printf`) so Discord filters apply.
7. Add a unit test next to the changed file. Existing tests use plain `testing` + table-driven cases.

## 10. Things That Will Bite Future-You

- `betting(make_predictions)` literally has parentheses in the JSON key — kept for backwards compat with the Python miner. Rename = config break.
- `streamers`, `game_priority`, `streamers_exclude`, `game_exclude` all lower-case + trim on read; user-facing case is purely cosmetic.
- `IsStreamLive` uses persisted op `WithIsStreamLiveQuery`; if Twitch rotates the SHA, all live-checks go silent and you can only tell from the `pubsub` reconnect log.
- `constants.ClientVersion` is a fallback; `(*Twitch).UpdateClientVersion` refreshes it from twitch.tv every 10h.
- Drop claim path uses `Inventory` op only (Python miner also walked `ViewerDropsDashboard`). Some campaigns won't appear in inventory until in-progress, so `pollPendingClaims` is the safety net.
- `cookies/<username>.json` is mode `0600`. Don't change to `0644` without revisiting threat model — token gives full account control.

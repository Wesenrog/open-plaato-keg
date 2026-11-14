# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Open Plaato Keg is an Elixir application that reverse-engineers the Blynk protocol used by
Plaato Keg homebrew scales, allowing local operation without the discontinued Plaato cloud
service. It acts as a local Blynk server replacement, decoding TCP data from keg hardware and
exposing it via an HTTP REST API and a WebSocket.

This is a **keg-weight-only** build. There is no airlock/fermentation support, no CO₂ keg mode,
no tap-list/beverage database, and no MQTT/BarHelper/Brewfather/Grainfather/Prometheus/OTA
integrations. The web UI is three pages: Serving, Kegging, and Keg Devices.

## Build & Development Commands

```bash
mix deps.get                       # install dependencies
mix run --no-halt                  # run the application locally
mix test                           # run all tests (alias runs with --no-start)
mix test test/decoder_test.exs     # run a single test file
mix test test/decoder_test.exs:42  # run a specific test by line number
mix credo --strict                 # lint
docker build -t open-plaato-keg .  # build a Docker image
mix release                        # build an Elixir release
```

`local/keg_simulator.exs` replays the captured Blynk frames in `local/bin/` against a running
server (`mix run --no-start local/keg_simulator.exs`).

## Required Toolchain

Defined in `.tool-versions` (for asdf): Elixir 1.16.2-otp-26, Erlang 26.2.5.

## Architecture

### Data Flow

Raw TCP bytes from Plaato Keg hardware go through a three-stage decoding pipeline:

1. **BlynkProtocol** (`blynk_protocol.ex`) — Decodes/encodes the binary Blynk wire protocol
   (command type, message ID, length, body). Also provides `encode_command/3` for sending
   commands back to the keg.
2. **PlaatoProtocol** (`plaato_protocol.ex`) — Interprets Blynk commands into Plaato-specific
   operations (login with auth token, hardware pin writes, internal metadata).
3. **PlaatoData** (`plaato_data.ex`) — Maps Plaato virtual pin numbers to keg properties
   (amount_left, keg_temperature, firmware_version, etc.). Airlock pins and the beer-info /
   CO₂-mode pins are intentionally not mapped.

### Connection Handling

- **KegConnectionHandler** — ThousandIsland TCP handler; one process per connection. Buffers
  reads into whole Blynk frames (`BlynkProtocol.parse/2`, frame body ≤ 1 KB). The port is
  meant to face the internet, so before login a connection may send only `internal` frames and
  the login, within 1 KB and 10 s, and gets nothing back: no ack, no `KegSocketRegistry`
  entry, nothing stored. The login must carry a 32-hex id that is on the allow-list (with
  none set, any well-formed id is accepted); anything else closes the socket with one log line.
  After login: one ack per read, frames with a non-UTF-8 body are dropped, a login with
  another id closes the connection, and a new connection logging in with the same id takes
  over from the earlier one.
  One address may hold twice as many connections as there are scales on the allow-list
  (`AllowList.scales/1`; sixteen when any id may log in), counted in `KegPeerRegistry`: every
  scale and a reconnect of each. An IPv6 /64 is one address. Further connections are closed
  unanswered, with at most one log line per ten seconds.
- **KegDataProcessor** — Functions run inside the handler process (no process of its own):
  decodes a logged-in keg's frames, classifies the connection as a keg, and fans out to the
  `KegData` store and the `WebSocketHandler`.
- **AllowList** (`allow_list.ex`) — The ids that may log in: `KEG_ALLOWED_IDS` plus the lines
  of the file in `KEG_ALLOWED_IDS_FILE`, which is read at every login (no restart to change
  it). A file that is set but unreadable allows nothing. A line may name the keg (`<id>
  <name>`): the keg is then registered and stored under the name, so its id can change
  (`KegData.rename/2` moves a keg already stored under its id).
- **KegId** (`keg_id.ex`) — Id format, canonical (lower-case) form, and `short/1` for logs.
- **KegCommander** (`keg_commander.ex`) — Sends commands back to connected kegs via
  `KegSocketRegistry`: tare, known-weight calibration, empty-keg weight, max keg volume,
  sensitivity, temperature offset, and pin sync.

### Storage

- Uses Erlang `:dets` for persistence. One table, `:keg_data`, is opened at startup at
  `DATABASE_FILE_PATH`.
- **KegData** model (`models/keg_data.ex`) — Reads/writes keg state to `:keg_data`; merges
  incoming property updates; derives `beer_left_unit` (`"litre"` or `"kg"`).

### HTTP Layer

- **HttpRouter** (`http_router.ex`) — Plug/Bandit router serving:
  - Reads: `/api/kegs`, `/api/kegs/devices`, `/api/kegs/connected`, `/api/kegs/:id`, `/api/alive`.
  - Commands `/api/kegs/:id/*`: `tare`, `tare-release`, `empty-keg-weight`, `max-keg-volume`,
    `calibrate-known-weight`, `temperature-offset`, `sensitivity`, `label`, `contents`, `delete`;
    plus `/api/kegs/order`.
  - `/ws` (WebSocket upgrade) and static files from `priv/static`.
- **WebSocketHandler** — Broadcasts to browser clients via `WebSocketConnectionRegistry`. Keg
  updates send the keg JSON plus `connected` (false in the update published when a scale
  drops); deletions send `%{type: "keg_removed", id: ...}`.

### Web UI (`priv/static`)

A "keg" in the code, the store and the API is a **scale**. Kegs come and go: several are
filled on one scale, and a full keg is served from any scale until it is empty.

- `index.html` — **Serving** page: up to three scales, landscape-tablet layout. Shows litres
  left only (1 litre per kg, never below zero, warning under 2 L) and the keg tare in effect,
  which is typed in from the weight printed on the keg.
- `kegging.html` — **Kegging** page: one selected scale, guided empty→fill flow. Step 1 zeroes
  with the empty keg, tubes and filter on; that zero is for the fill, not the keg's tare.
- `devices.html` — **Keg Devices** page: what belongs to the scale (name, zero the bare scale,
  known-weight calibration, sensitivity, temperature offset, remove).
- `app.css` / `app.js` — shared styles and helpers (top bar, `api()`, `connectWs()`, toasts).

### Supervision Tree

`OpenPlaatoKeg.Supervisor` (strategy `:one_for_one`) starts: WebSocket connection registry,
keg socket registry, keg peer registry (open connections per address), TCP listener (ThousandIsland), HTTP server (Bandit → `HttpRouter`).

### Configuration

All runtime config is in `config/runtime.exs` via environment variables: `KEG_LISTENER_PORT`,
`HTTP_LISTENER_PORT`, `DATABASE_FILE_PATH`, `INCLUDE_UNKNOWN_DATA`, `KEG_ALLOWED_IDS`,
`KEG_ALLOWED_IDS_FILE`. The
listener's connection limits are in `supervisor.ex` and have to stay under the container's
file-descriptor limit; the handler reads the allow-list from the config, it is not a listener
option (those are printed when an acceptor crashes). The `OpenPlaatoKeg.Config`
module (`config_tools.ex`) provides typed env var parsing.

## Testing

Tests use `--no-start` (the application is not started during tests). `test/decoder_test.exs`
holds a full snapshot of decoding every frame in `local/bin/` through the pipeline — regenerate
it deliberately after decoder changes. Journey tests in `test/journeys/` cover pin-level decode
cases. The `assert_value` library is available for snapshot-style assertions.

## Key Conventions

- The empty-keg pin (62) takes a weight in kg, and the scale does not report it back: the
  stored `empty_keg_weight` is what was last sent. It is not a button: sending `1` then `0`
  sets a tare of 1 kg and then 0 kg and captures nothing (checked on a scale). To zero
  with what is on the platform, send `amount_left + empty_keg_weight` (the Kegging page does).

- Keg IDs are 32-character hex strings (the Blynk auth token), lower-cased at login. The id is
  all a keg has to identify itself: logs carry `KegId.short/1`, never the id.
- The key a keg has in the store, the registry and the API (`:id`) is its id, or its name
  from the allow-list file. Nothing may assume that key is 32 hex characters.
- Keg properties flow as keyword lists through the decode pipeline.
- Locally-stored, user-defined fields are prefixed with `my_` and never sent to hardware:
  `my_label` is the scale's name (Keg Devices), `my_contents` what is in the keg on it (Serving),
  `my_sort_order` its place on the Serving page (set by dragging, behind a lock).
- The app version is read from `.release/version` at compile time.

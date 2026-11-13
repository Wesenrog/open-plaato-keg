# open-plaato-keg

`open-plaato-keg` is an Elixir/OTP application that provides a local, self-hosted replacement
for the discontinued Plaato cloud, for **Plaato Keg scales only**. It speaks the
reverse-engineered Blynk TCP protocol directly to the hardware.

This build is keg-weight-only: no airlock/fermentation, no CO₂ keg mode, no tap-list/beverage
database, and no MQTT/BarHelper/Brewfather/Grainfather/Prometheus/OTA integrations.

See `CLAUDE.md` for the full architecture and conventions. Quick summary:

## Components

* **TCP listener** (ThousandIsland) — receives data from and sends commands to Plaato Keg scales.
* **HTTP server** (Bandit → `OpenPlaatoKeg.HttpRouter`) — REST API for kegs plus the static web
  UI: `/index.html` (Serving), `/kegging.html` (Kegging), `/devices.html` (Keg Devices).
* **WebSocket** (`/ws`) — real-time keg updates for the web UI.
* **Storage** — one Erlang `:dets` table, `:keg_data`, at `DATABASE_FILE_PATH`.

## Decode pipeline

`BlynkProtocol` (wire frame) → `PlaatoProtocol` (Blynk commands) → `PlaatoData` (virtual pin →
keg property). `KegCommander` encodes the reverse direction.

## Building and running

```bash
mix deps.get
mix run --no-halt        # run locally
mix test                 # run the suite (aliased to --no-start)
mix credo --strict       # lint
mix release              # build a release
```

## Configuration

Environment variables (via `config/runtime.exs`): `KEG_LISTENER_PORT` (default 1234),
`HTTP_LISTENER_PORT` (default 8085), `DATABASE_FILE_PATH`, `INCLUDE_UNKNOWN_DATA`,
`KEG_ALLOWED_IDS` (comma-separated keg ids that may connect; empty accepts any).

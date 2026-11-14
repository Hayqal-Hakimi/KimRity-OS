# KimAI v0.2 - local approval broker and event sink

KimAI is a background service (a broker) that lives inside the user session.
Other tools - **KimScanning** and **KimLogPipe** - talk to it over a Unix
socket. It never acts on its own: no polling, no timers, no network calls.

Two jobs:

| Job | Who uses it | What KimAI does |
| --- | --- | --- |
| Approval queue | KimScanning (actions that need a human) | Holds the request until the operator decides. **The decision always belongs to KimAI**, never to the calling tool. |
| Event sink | KimLogPipe (live findings) | Records the finding append-only and raises a desktop notification for high severity. |

## Requirements

- Python 3 (standard library only)
- Linux with Unix sockets and `SO_PEERCRED`
- Optional: `notify-send` (libnotify) for desktop notifications

## Quick start

```bash
chmod +x kimai/kimai

# Terminal 1: run the daemon in the foreground
./kimai/kimai start

# Terminal 2
./kimai/kimai status
./kimai/kimai approve list
```

In a real session the daemon is started by systemd, not by hand. See
"Running as a systemd user service" below.

## Design rules

1. **The broker is local only.** No HTTP client, no remote API, no model call
   unless you explicitly configure a `command` for `ask`.
2. **Alive does not mean calling a model.** A running KimAI costs nothing while
   it is idle. Cost only appears when a tool calls `ask` and a command is
   configured.
3. **Tools degrade, they do not fail.** If KimAI is down, callers must fall
   back to tools-only mode. KimLogPipe keeps working; KimScanning keeps
   scanning.
4. **Append-only audit.** Approvals and events are appended to JSONL files and
   never rewritten.
5. **Decisions are recorded, not implied.** Every approval row carries the
   decision (`approve`/`reject`), the note and the original arguments.

## Socket path

KimAI picks the first usable location:

1. `$XDG_RUNTIME_DIR/kimai.sock`
2. `/run/user/<uid>/kimai.sock`
3. `~/.cache/kimai/kimai.sock`

The socket is created with mode `0600` inside a `0700` directory. Every
connection is checked with `SO_PEERCRED`: a client with a different UID is
refused.

## Protocol

Line-delimited JSON over the Unix socket. Each connection may send one or more
requests; each line is one JSON object.

Request:

```json
{"id":"<any>","op":"<name>","args":{...}}
```

Success:

```json
{"id":"<same>","ok":true,"result":{...}}
```

Failure:

```json
{"id":"<same>","ok":false,"error":"<message>"}
```

`id` is echoed back unchanged. `args` may be omitted or `{}` when the op does
not need it. Blank lines are ignored.

## Operations

| Op | Args | Result |
| --- | --- | --- |
| `ping` | - | `{"pong":true,"version":"0.2.0"}` |
| `status` | - | `{"version","uptime_s","ai_enabled","pending_approvals","events_received","notify","socket"}` |
| `ask` | `{"prompt":"..."}` | `{"answer":"..."}` when a `command` is configured; otherwise the error `AI is not configured` |
| `event` | `{"source","kind","severity","summary","data"}` | `{"event_id":"ev-...","notified":true\|false}` |
| `event.list` | `{"limit":N}` | `{"events":[...]}` (oldest first, last N) |
| `approve.request` | `{"tool","action","args","risk","reason"}` | `{"request_id":"req-..."}` |
| `approve.list` | - | `{"pending":[...],"recent":[...]}` |
| `approve.decide` | `{"request_id","decision":"approve\|reject","note":""}` | `{"request_id","decision","note"}` |
| `shutdown` | - | `{"shutdown":true}` (used by `kimai stop`) |

An unknown op returns `ok:false` with the message `Unknown op: <name>`.

### `event`

`severity` must be one of `low`, `medium`, `high`, `critical`. `data` must be a
JSON object (default `{}`). Each event is appended to
`$XDG_DATA_HOME/kimai/events.jsonl`:

```json
{"ts":"2026-11-14T05:49:14.475Z","event_id":"ev-ffd1...","source":"kimlogpipe",
 "kind":"ssh_bruteforce","severity":"high",
 "summary":"6 failed SSH authentications from 10.0.2.2 in 300s",
 "data":{"src_ip":"10.0.2.2","count":6}}
```

`events.jsonl` is rotated to `events.jsonl.1` once it passes 5 MB, so the file
cannot grow without bound.

### `ask`

The configured `command` runs with the prompt on stdin. Its stdout becomes the
answer. There is a 120 second timeout and a 1 MB line limit.

## Notifications

`event` raises a desktop notification (`notify-send`) when severity is `high`
or `critical`. It is fire-and-forget: a missing notifier never blocks or
breaks the broker.

Disable it with an environment variable on the service:

```ini
Environment=KIMAI_NOTIFY=0
```

`status.notify` reports the current setting.

## Append-only records

| File | Written by | Contents |
| --- | --- | --- |
| `$XDG_DATA_HOME/kimai/approvals.jsonl` | `approve.request`, `approve.decide` | one row per request, one row per decision |
| `$XDG_DATA_HOME/kimai/events.jsonl` | `event` | one row per finding |

Request row:

```json
{"ts":"...","request_id":"req-...","tool":"KimScanning","action":"scan-directory",
 "args":{"target":"/tmp"},"risk":"medium","reason":"integration test",
 "decision":null,"note":""}
```

Decision row (same `request_id`, `decision` filled in):

```json
{"ts":"...","request_id":"req-...","tool":"KimScanning","action":"scan-directory",
 "args":{"target":"/tmp"},"risk":"medium","reason":"integration test",
 "decision":"approve","note":"checked by hand"}
```

## How KimScanning asks for approval

KimScanning has no approval UI of its own. It sends a request and waits for the
decision to appear:

```json
{"id":"1","op":"approve.request","args":{
  "tool":"KimScanning",
  "action":"delete-quarantine",
  "args":{"path":"/home/user/.cache/kimscan/q/abc"},
  "risk":"high",
  "reason":"remove quarantined file after review"}}
```

Then it polls `approve.list`, or reads the ledger, until the row for its
`request_id` has a non-null `decision`. If KimAI is not running, KimScanning
must continue in tools-only mode.

## CLI

```bash
kimai start
kimai stop
kimai status
kimai ask "<prompt>"
kimai events [--limit N]
kimai approve list
kimai approve yes <request_id> [--note "..."]
kimai approve no  <request_id> [--note "..."]
```

`kimai events` reads `events.jsonl` directly (no daemon needed), so it also
works when the service is stopped.

## Configuration

Optional file: `~/.config/kimai/config.toml`.

```toml
command = "/usr/local/bin/local-llm --stdin"
```

The `[ai]` table form is also accepted. Without this file, `ask` returns
`AI is not configured` and everything else keeps working.

## Running as a systemd user service

Unit: `systemd/user/kimai.service` (installed to
`/usr/lib/systemd/user/kimai.service`).

```bash
systemctl --user enable --now kimai.service
systemctl --user status kimai.service
loginctl enable-linger "$USER"   # alive without an open terminal
```

The unit restarts on failure and starts with the user session. It does not
need root and does not open a network port.

## Notes on monitoring

KimAI does **not** watch anything by itself. A cron job or a timer that feeds it
events is an opt-in decision by the operator, not default behaviour. KimLogPipe
is the component that watches logs; KimAI only records what it is told.

## Tests

```bash
./kimai/test/run_tests.sh
```

The test suite runs against a temporary `HOME`, `XDG_DATA_HOME` and
`XDG_RUNTIME_DIR`; it never touches the real session. It covers the socket
mode, `ping`, `status`, `ask` without configuration, the full approval
lifecycle, the event sink, invalid input and shutdown behaviour.

## Version history

| Version | Change |
| --- | --- |
| 0.1.0 | Approval broker: `ping`, `status`, `ask`, `approve.*`, `shutdown`. Malay strings, `lulus`/`tolak` decisions. |
| 0.2.0 | English throughout. `approve`/`reject` decisions. New `event` and `event.list` ops with desktop notifications. `events_received` in `status`. `kimai events` CLI. |

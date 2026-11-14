# KimLogPipe v2

KimLogPipe turns system logs into **one uniform event schema**, runs threshold
rules over those events, and - in live mode - pushes findings to **KimAI**.

- No AI, no model, no network. One executable: `kimlogpipe/kimlogpipe`
  (Python 3, standard library only).
- Every finding carries `raw_ref` evidence, so it can always be traced back to
  the original log line. Nothing is invented.
- All writes go to `$XDG_DATA_HOME/kimlogpipe/` (fallback
  `~/.local/share/kimlogpipe/`). Nothing is written to `/etc`,
  `~/.config`, or the source tree.

## The pipeline

```
journald  ─┐
           ├─> normalize ─> events.jsonl ─> rules ─> findings.jsonl ─> KimAI
auditd    ─┘                                   │
                                               └─> report (human)
```

Three stages, each one inspectable:

1. **Ingest** - read `journalctl -o json` and/or `/var/log/audit/audit.log`.
2. **Normalize** - every line becomes one of:

   ```json
   {"ts":"2026-11-14T05:53:54.829090Z","source":"journald","host":"arch",
    "user":"admin","src_ip":"203.0.113.77","action":"ssh_invalid_user",
    "outcome":"failed","raw_ref":"s=...;i=83a6c;...","path":""}
   ```

   `action` is the vocabulary the rules speak (`ssh_auth_failed`,
   `ssh_drop`, `sudo_fail`, `execve:nmap`, `etc_change`, ...). `outcome` is
   `success`, `failed` or `unknown`.

3. **Detect** - run the rules in `rules.yaml`. Every threshold is data; the
   engine hard-codes none.

## Modes

### One-shot

```bash
# Ingest a fixture or a live snapshot
kimlogpipe ingest --source journald --file kimlogpipe/fixtures/f_sshd.jsonl
kimlogpipe ingest --source journald
kimlogpipe ingest --source auditd --file kimlogpipe/fixtures/f_audit.log

# List rules and thresholds
kimlogpipe rules

# Evaluate every rule (all events, or a time window)
kimlogpipe detect
kimlogpipe detect --since 5m

# Human-readable report
kimlogpipe report

# Live state and store counters
kimlogpipe status
```

One-shot ingest is idempotent: events are de-duplicated on
`ts + source + action + raw_ref`, so ingesting the same fixture twice adds
nothing.

### Live

```bash
kimlogpipe follow                    # journald + auditd
kimlogpipe follow --source journald  # journald only
kimlogpipe follow --source auditd    # audit log only
kimlogpipe follow --no-kimai         # tools-only, no broker
```

`follow` is designed to run under systemd (see below). It:

- reads `journalctl -f -o json` and resumes from the saved cursor after a
  restart;
- tails the audit log from the saved byte offset and survives log rotation;
- on the very first run (no saved offset) it starts at the **end** of the audit
  log, exactly like `journalctl -n 0` for journald, so a freshly installed
  monitor does not alert on changes that predate it;
- appends new events immediately (no full-file rewrite);
- re-evaluates the rules over a rolling window, so a threshold can be reached
  across a restart;
- writes each new finding to `findings.jsonl` and pushes it to KimAI as an
  `event`;
- **keeps running when KimAI is down** - it logs `continuing in tools-only
  mode` and keeps recording findings.

## Rules

| Rule | Type | What it catches |
| --- | --- | --- |
| `ssh_bruteforce` | threshold | 5+ failed SSH signals from the same `src_ip` within 300s |
| `sudo_fail` | any_failed | any failed `sudo` / `su` authentication |
| `audit_exec_watch` | exec_watch | execution of `nmap`, `nc`, `curl`, `wget` via `execve` |
| `etc_watch` | any_match | a change under a path watched by auditd with `-k etc_watch` |

`ssh_bruteforce` counts three signals: `ssh_auth_failed`,
`ssh_invalid_user` and `ssh_drop`. The last one matters because sshd
`PerSourcePenalties` can truncate a burst, so a failed attempt may appear as
`drop connection` instead of `Invalid user`. Three real shapes are understood:

```
Failed password for root from 203.0.113.9 port 41022 ssh2
drop connection #0 from [10.0.2.2]:60362 on [10.0.2.15]:22 penalty: failed authentication
Connection closed by authenticating user root 10.0.2.2 port 60316 [preauth]
```

In the penalty forms the remote peer is `10.0.2.2`; the address after `on` is
the local socket and is ignored.

Each rule has a `cooldown_seconds` value. In live mode the same rule/key pair
is not pushed again until the cooldown has passed **and** newer events arrived.
This is alert de-duplication, not suppression of evidence: the finding stays in
`findings.jsonl`.

### AIDE is gone

v1 had an `aide_change` rule, but AIDE was never installed, so the rule could
never fire. v2 replaces it with `etc_watch`, which uses auditd - already
installed and enabled. The audit rules live in
`systemd/system/kimrity-audit.rules` and are installed to
`/etc/audit/rules.d/kimrity.rules`.

```bash
# /etc/audit/rules.d/kimrity.rules (excerpt)
-w /etc/passwd -p wa -k etc_watch
-w /etc/shadow -p wa -k etc_watch
-w /etc/sudoers -p wa -k etc_watch
```

A change produces an audit `PATH` record with `key="etc_watch"`, which becomes
`action="etc_change"` with the affected `path`.

Two kinds of noise are filtered on purpose:

- `CONFIG_CHANGE` records (rule loading) carry the watch key but are not file
  changes; they become `audit_rule_load` and never a finding.
- `/etc/resolv.conf` is not watched: NetworkManager replaces it on every DHCP
  renew, so it produced one finding per boot for a temp file name.

## Storage

| File | Contents |
| --- | --- |
| `events.jsonl` | one normalized event per line, append-only in live mode |
| `rawlines.jsonl` | the raw log line for each `raw_ref` (evidence sidecar) |
| `findings.jsonl` | findings emitted by `follow`, one JSON object per line |
| `findings.json` | the latest snapshot written by `detect` / `follow` |
| `state.json` | journald cursor, audit offset/inode, alert cooldowns, counters |

`events.jsonl` and `rawlines.jsonl` rotate to `.1` once they pass 20 MB.

## Permissions

`follow` runs as a **user service**, so it needs read access:

- **journald** - the user must be in the `systemd-journal` group. The installer
  adds this.
- **audit log** - `/var/log/audit/audit.log` is `root:root 0600` by default.
  The installer sets `log_group = systemd-journal` in `/etc/audit/auditd.conf`
  so the file becomes group-readable.

If the audit log is unreadable, `follow` says so and continues with journald
only; `etc_watch` is then reported as not evaluable rather than "no change".
The check is repeated every loop, so fixing the permissions (or the log
appearing after boot) recovers without a service restart.

## KimAI integration

Each new finding is sent as one KimAI `event`:

```json
{"op":"event","args":{
  "source":"kimlogpipe","kind":"etc_watch","severity":"medium",
  "summary":"1 watched-path change(s) for /etc/passwd (latest: /etc/passwd).",
  "data":{"rule":"etc_watch","key":"/etc/passwd","count":1,
          "first_ts":"...","last_ts":"...",
          "evidence":[{"raw_ref":"/var/log/audit/audit.log:2",
                       "line":"type=SYSCALL ..."}]}}}
```

The socket is found at `$XDG_RUNTIME_DIR/kimai.sock` (or the first existing of
`/run/user/<uid>/kimai.sock`, `~/.cache/kimai/kimai.sock`). Override with
`KIMAI_SOCKET`. Disable with `--no-kimai` or `KIMLOGPIPE_KIMAI=0`.

KimAI decides what to do with the event (record it, notify the desktop).
KimLogPipe never asks for permission to act; it only reports.

## Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `KIMLOGPIPE_AUDIT_LOG` | `/var/log/audit/audit.log` | audit log path |
| `KIMLOGPIPE_RULES` | next to the binary / `/usr/local/share/kimlogpipe/rules.yaml` | rules file |
| `KIMLOGPIPE_JOURNAL_LINES` | `2000` | line count for one-shot journald ingest |
| `KIMLOGPIPE_FLUSH_SECONDS` | `1.0` | follow loop interval |
| `KIMLOGPIPE_RING` | `5000` | events kept in the rolling window |
| `KIMLOGPIPE_KIMAI` | `1` | set `0` for tools-only |
| `KIMLOGPIPE_FORCE_MINI_YAML` | unset | `1` forces the built-in YAML parser |
| `KIMAI_SOCKET` | auto | KimAI socket path |

## systemd user units

```bash
systemctl --user enable --now kimai.service
systemctl --user enable --now kimlogpipe.service
systemctl --user status kimlogpipe.service
journalctl --user -u kimlogpipe -f
```

Units live in `systemd/user/` in this repo and are installed to
`/usr/lib/systemd/user/`. `loginctl enable-linger <user>` keeps both services
alive without an open terminal.

`kimlogpipe.service` declares `After=kimai.service` and `Wants=kimai.service`:
KimAI is preferred, but its absence does not stop the pipeline.

## Report

`kimlogpipe report` prints events by source, findings by rule, the top keys and
the caveats that matter when reading the numbers:

- journald is not persistent by default (`Storage=volatile`);
- `PerSourcePenalties` truncation;
- QEMU NAT collapses every external source into `10.0.2.2`;
- a rule without data is "not evaluable", never "no attack".

## Tests

```bash
./kimlogpipe/test/run_tests.sh
```

The suite covers the schema, de-duplication, both YAML parsers, every rule,
`--since`, the report, storage isolation, and two live `follow` scenarios
(audit tail -> rule -> KimAI event, and KimAI down -> tools-only). When
`journalctl` is readable it also injects real journal lines through `logger`
and checks that a brute-force finding appears.

Everything runs inside a temporary `HOME`/`XDG_DATA_HOME`/`XDG_RUNTIME_DIR`.

## Version history

| Version | Change |
| --- | --- |
| 1.0 | One-shot ingest, 4 rules, Malay report, `aide_change`. |
| 2.0 | English throughout. `follow` live mode with cursor/offset resume. Incremental append and rotation. Alert cooldown state. `etc_watch` replaces AIDE. KimAI event push with tools-only fallback. `status` command. |

# KimScanning v1

KimScanning is a command-line tool in the style of `nmap` that wraps
[`gate/gate.py`](../gate/gate.py). Every scan is stored as a **session
object**, every finding is explained in **English from a static dictionary**
(`rules/en.yaml`), and finding statuses are kept consistent across repeated
scans. No AI, no network calls made by KimScanning itself.

KimScanning does not produce its own verdict: the verdict comes from the
KimRity Security Gate. If a scanner tool is missing or fails, the gate does
not approve and KimScanning records that honestly.

## Requirements

- Python 3 (standard library only; PyYAML is used if present, otherwise a
  small built-in parser is used).
- `gate/gate.py` in the same repository.
- Scanner tools on `PATH`:
  - `repo`: `gitleaks`, `semgrep`, `trivy`
  - `file`: `gitleaks`, `semgrep`, `trivy`; metadata from `file` and
    `sha256sum`. Binary files additionally try `clamscan` and `yara` if
    available.
  - `installer`: `.sh`, `.deb`, `.rpm`, `.AppImage`, `.run`, `.bin`, `.exe`,
    or `PKGBUILD`; uses the same checks as `file`.
  - `web`: `nuclei`, `nikto`
  - `server`: `nmap`, `ssh-audit` (ssh-audit only if port 22 is open)
- `kimscan doctor` checks each tool with `command -v` (via `shutil.which`)
  and reports missing tools as **absent**. It never treats an uninstalled
  tool as present.

## Usage

```text
kimscan repo <folder> [--scope S] [--json] [--fail-on critical|high|medium]
kimscan file <path> [--json] [--fail-on critical|high|medium]
kimscan installer <path> [--json] [--fail-on critical|high|medium]
kimscan web <url> --authorized [--scope S] [--json] [--fail-on T]
kimscan server <host> --authorized [--scope S] [--json] [--fail-on T]
kimscan list
kimscan show <id> [--json]
kimscan status <id> <fp> new|accepted|fixed
kimscan rules [--missing]
kimscan doctor
kimscan help
```

Examples:

```bash
./kimscanning/kimscan doctor
./kimscanning/kimscan repo .
./kimscanning/kimscan repo ~/project --fail-on medium
./kimscanning/kimscan file ./settings.py
./kimscanning/kimscan installer ./install.sh
./kimscanning/kimscan web https://127.0.0.1 --authorized --scope scope.txt
./kimscanning/kimscan show 20261028T120000Z
./kimscanning/kimscan status 20261028T120000Z a1b2c3d4e5f6 accepted
./kimscanning/kimscan rules --missing
```

`web` and `server` are active scans. Both **refuse to run** without
`--authorized` and exit with code 1. The user is responsible for making sure
written authorization exists before using that flag.

### Single files and installers

`gate.py` only accepts a repo/folder for `repo` mode; it cannot take a
single file directly. For `file` and `installer`, KimScanning copies the
file to a temporary directory containing just that one file, scans it via
the Gate's `repo` mode, then deletes the temporary directory. The target
and `file_path` in the session remain the original file path.

Text files still receive a normal Gate scan (`gitleaks`, `semgrep`,
`trivy`). `file` and `sha256sum` are always recorded when available. For
binaries or `installer` artifacts, KimScanning also runs `clamscan` when
present. YARA needs rules; it runs only if `KIMSCAN_YARA_RULES` points to a
readable rules file. If a tool is missing, its status says
`available: no` clearly — KimScanning does not invent scan results.

### NDJSON for a GUI

With `--json`, stdout contains only one JSON object per line:

```json
{"phase":"start","id":"20261028T120000Z","kind":"repo","target":"/x","started":"..."}
{"phase":"scanner","name":"gitleaks","status":"done","rc":0,"reason":"done"}
{"phase":"scanner","name":"semgrep","status":"done","rc":0,"reason":"done"}
{"phase":"done","id":"20261028T120000Z","verdict":"PASS","counts":{...},"exit":0}
```

Guard errors and usage errors are written to stderr.

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | PASS |
| 1 | usage error / authorization guard |
| 2 | CONDITIONAL |
| 3 | FAIL |

The gate verdict `CONDITIONAL` is kept as-is in `session.json` so it exactly
follows the session schema.

## Sessions

Location:

```text
$XDG_DATA_HOME/kimscanning/sessions/<YYYYMMDDTHHMMSSZ>/
```

If `XDG_DATA_HOME` is not set:

```text
~/.local/share/kimscanning/sessions/<YYYYMMDDTHHMMSSZ>/
```

Each session contains:

- `session.json` — the session object (schema below)
- `raw/` — raw output of each scanner, `gate.json`, and the gate report
- `report.md` — human report

`session.json` schema:

```text
id, kind, target (absolute for repo), profile,
authorized{granted,who,when,scope},
started, finished, verdict (PASS|CONDITIONAL|FAIL),
scanners[{name,status(done|failed|skipped),rc,reason}],
counts{critical,high,medium,low},
findings[{fp,tool,rule,severity,file,line,message,evidence,
          explanation{what,why,fix} | null,
          status(new|accepted|fixed),first_seen,last_seen}]
```

Sessions for `file` and `installer` also contain `file_path` (the original
path), `sha256`, `size_bytes`, and `file_type` (output of `file -b`).

Scans rejected before the scanners run — for example `web` without
`--authorized` — do not create a session directory. `list` skips corrupted
session records and `show` reports a clear error, so old broken sessions do
not make those commands crash.

### Fingerprints and status

```text
fp = sha1(tool + "|" + rule + "|" + file + "|" + line)[:12]
```

When a new scan of the same `kind+target` produces an `fp` seen before:

- the original `first_seen` is kept;
- `last_seen` is updated;
- the original status is kept (it is not reset to `new`).

Status is only changed through:

```bash
kimscan status <id> <fp> new|accepted|fixed
```

Status changes are recorded in the session and in a small ledger at
`$XDG_DATA_HOME/kimscanning/status.json` so the next scan of the same
`kind+target+fp` uses the latest status, even if it was set in an older
session. The ledger also lets a status be changed back to `new`.

## Rule dictionary (no AI)

`rules/en.yaml` maps `tool` + `rule` to three English fields:

- `what` — what was detected;
- `why` — why it is dangerous;
- `fix` — the remediation action.

All ids in the dictionary were copied from real gitleaks, semgrep, and
trivy output via `gate/gate.py`. No invented ids.

If a rule is not in the dictionary:

- `session.json` stores `"explanation": null`;
- the CLI shows `[no explanation]`;
- `kimscan rules --missing` lists `tool/rule` pairs seen in sessions but
  missing from the dictionary, with finding and session counts.

`kimscan rules` without a flag lists every dictionary entry.

## Tests

Tests use temp `HOME` and `XDG_DATA_HOME` so real configuration is not
touched:

```bash
bash kimscanning/test/run_tests.sh
```

The tests create clean and leaking folders under a temp directory, generate
random AWS-style keys with `tr -dc 'A-Z2-7'`, and then check verdicts, exit
codes, sessions, explanations, status carry-over, rejection of `web` without
authorization, `rules --missing`, and `doctor`.

To run the tests with tools from a temp directory:

```bash
PATH=/tmp/opencode/bin:$PATH bash kimscanning/test/run_tests.sh
```

## v1 limits

- No full-screen UI yet; this is a command-line tool.
- Real `web`/`server` scans require an authorized target and the tools
  `nuclei`/`nikto`/`nmap`/`ssh-audit`. If a tool is missing, the gate gives
  FAIL for lack of evidence.
- KimScanning does not invent rule ids, does not call AI, and does not
  produce its own verdict.

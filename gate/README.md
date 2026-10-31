# KimRity Security Gate — v2 (code repo · web · server)

One tool that **uses other tools** to check a target and produce a
**PASS / CONDITIONAL / FAIL** decision.

No AI model is involved in the decision. The verdict comes from the
severity reported by the tools, following the rules in `gate.py`.

## Use

```sh
python3 gate.py <target> [--kind repo|web|server] [--scope FILE] [--authorized] \
                [--out DIR] [--fail-on critical|high|medium] [--quiet]
```

Defaults: `--out gate-out`, `--fail-on high`. The kind is guessed when
`--kind` is absent (folder → repo · URL → web · host/IP → server).

**Guard:** web/server scans **require** `--authorized` (you confirm you are
authorized to scan the target). If `--scope FILE` is given, the target must
be listed in that file (one target/CIDR per line, `#` for comments) —
matching §4.7 of the draft.

## Tools run

| Kind | Tool | Looks for |
|---|---|---|
| **repo** | `gitleaks` | secrets in code + git history (always `high`) |
| | `semgrep --config p/default` | unsafe code patterns (follows semgrep severity) |
| | `trivy fs` | package CVEs, secrets, misconfigs (follows trivy severity) |
| **web** | `nuclei` | CVE/exposure templates (nuclei severity) |
| | `nikto` | web server misconfiguration (medium; suggested header = low) |
| **server** | `nmap -sV -sC` | exposed ports (risk table) + weak SSH/TLS algorithms |
| | `ssh-audit` | only if port 22 is open |

**ssh-audit tuning (intentional, documented):**
- `suspected as being backdoored` (NIST curve count) → **low** — an opinion of the tool, not breakage
- `post-quantum` → **info** — future-proofing advice
- other `[fail]` items (`broken SHA-1` etc.) → **high**; other `[warn]` → **medium**

**nmap port risk table:** 23/445/512-514/1433/3306/5432/6379/9200/27017 → high ·
21/3389/5900 → medium · 111 → low.

All three tools must produce output. A failed tool = **no evidence = FAIL**.

## Verdict rules

- an issue ≥ `--fail-on` (default `high`) → **FAIL** (exit 1)
- no high, but `medium` exists → **CONDITIONAL** (exit 0)
- nothing → **PASS** (exit 0)

## Output

- `gate-out/gate.json` — full evidence: tool versions, commit, all findings, verdict
- `gate-out/report.md` — human-readable summary

## Tests already run

| Kind | Test target | Verdict | Findings |
|---|---|---|---|
| repo | Random AWS key + SQLi + `flask==0.5` | FAIL | 18 (11 high, 6 medium, 1 low) |
| repo | `os-security-ai` (clean) | PASS | 0 |
| web | `http://127.0.0.1:8080` (exposed `.git/config`) | CONDITIONAL | 9 (4 medium, 5 low) — nuclei found `.git/config` |
| server | `127.0.0.1` (fake 3306 listener + sshd) | FAIL | 24 (3 high: port 3306, 2× hmac-sha1) |
| guard | web/server without `--authorized` | rejected, exit 1 | — |
| guard | target outside `--scope` | rejected, exit 1 | — |
| guard | target inside `--scope` | accepted | — |

Cross-check: the AWS key was found by **gitleaks**, **semgrep** and
**trivy** independently — three separate engines, not one.

## v2 limits

- No baseline (accepted old issues) yet — all issues are counted every time
- `semgrep p/default`, `trivy` and `nuclei` need a network on first run (rules/DB)
- Reports are not signed/hash-verified yet
- Full `nuclei` (13,619 templates) takes a few minutes per scan
- Server: only `--top-ports 1000` (not 65,535)
- Web: `nikto` is capped at 10 minutes

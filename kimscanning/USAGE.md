# KimScanning — How to Use

A short guide for beginners. If this is your first time, read sections 1–3
first.

## 1. What is this

KimScanning (`kimscan`) is a terminal scanner that checks folders, websites,
or hosts before you trust something. It runs existing security tools and
gives a verdict — PASS, CONDITIONAL, or FAIL.

## 2. Start here

Try the demo first. It uses a temp folder, so your files are never touched:

```bash
bash kimscanning/test/demo_aliran.sh
```

The real workflow has 3 steps.

**Step 1 — Check the tools.**
```bash
kimscan doctor
```
`gitleaks`, `semgrep`, `trivy` must be `available`. If not, repo scans
cannot be trusted.

**Step 2 — Scan.**
```bash
kimscan repo ~/my-project
```
For websites or hosts, add `--authorized` (see section 5):
```bash
kimscan web https://my-site.example --authorized
kimscan server 192.168.1.10 --authorized
```

**Step 3 — Read and mark.**
```bash
kimscan list
kimscan show 20261029T100935Z
kimscan status 20261029T100935Z 6f958f52bd43 accepted
```

Example output from the demo (folder paths shortened):

```
 KIMSCANNING v1   |   FAIL
Session   : 20261029T100935Z
Kind      : repo  (repo-standard)
Target    : .../leaky-target
Counts    : critical=0 high=3 medium=0 low=0
```

Those three high findings come from one AWS key in `config.env`. Gitleaks
names it `aws-access-token`.

## 3. Reading the verdict

| Verdict | Exit | Meaning | Action |
|---|---:|---|---|
| `PASS` | 0 | Nothing crossed the threshold. | Continue. |
| `CONDITIONAL` | 2 | Medium issues exist, no high/critical. | Fix before shipping to production. |
| `FAIL` | 3 | High/critical exists, or a tool failed. | Do not ship. Fix, then scan again. |
| Error | 1 | Wrong usage, or missing `--authorized`. | Fix the command. |

Important: `FAIL` also appears when a tool fails. It means "no evidence",
not "there must be malware". Do not assume it passed.

Every finding has `WHAT` (what was found), `WHY` (why it is dangerous),
`FIX` (how to remediate), and `EVIDENCE` (file and line). If it says
`[no explanation]`, that rule is not yet in the dictionary. Run
`kimscan rules --missing` to see the list.

## 4. Marking actions

Every finding has an `fp` (12-character fingerprint) and a `status`:

| Status | Meaning |
|---|---|
| `new` | Untouched. This is the default. |
| `accepted` | You know the risk and accept it (e.g. a test key). |
| `fixed` | You already fixed it. |

```bash
kimscan status <id> <fp> accepted
kimscan status <id> <fp> fixed
```

Why it matters: the status is stored and carried into the next scan of the
same target. Old findings stop showing up as `new`, so you can see what is
still left.

Example from the demo: after `6f958f52bd43` is marked `accepted`, the second
scan shows the same line with `status: accepted`.

Status does not change the verdict. The AWS key is still there, so the
verdict stays `FAIL`. Status is for your work, not for fooling the verdict.

If the `fp` is not visible in the output, run `kimscan show <id> --json`
and look for `"fp"`.

## 5. When `--authorized` is required

`repo` scans your own files. No authorization needed.

`web` and `server` send traffic to a host. That is an active scan. Without
written authorization it can be a criminal offence — in Malaysia, under the
Computer Crimes Act 1997. Do not scan other people's hosts, even "just to
test".

Without `--authorized`, the tool refuses and exits with code 1. Do not
attempt to work around it. Use `--scope` to limit targets to an allowlist.

## 6. Full command list

| Command | Use |
|---|---|
| `kimscan repo <folder>` | Scan a local folder/repo. |
| `kimscan web <url> --authorized` | Scan a website. |
| `kimscan server <host> --authorized` | Scan a host/IP. |
| `kimscan list` | List all sessions. |
| `kimscan show <id>` | Show one full session. |
| `kimscan status <id> <fp> new / accepted / fixed` | Mark an action. |
| `kimscan rules` | List the explanation dictionary. |
| `kimscan rules --missing` | Rules seen but with no explanation. |
| `kimscan doctor` | Check available tools. |
| `kimscan help` | Short help. |

Sessions are stored at `$XDG_DATA_HOME/kimscanning/sessions/<id>/`
(default `~/.local/share/kimscanning/sessions/`). Each session has
`session.json`, `report.md`, and `raw/`.

That is all. Start with `doctor`, scan one folder, read `show`, and mark one
finding. Repeat.

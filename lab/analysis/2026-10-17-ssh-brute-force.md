# Incident Analysis — SSH Brute Force (controlled simulation)

| | |
|---|---|
| **Date** | 2026-10-17, 09:44–09:45 local time (+08) |
| **Machine** | `arch-uji` (QEMU VM, kernel 7.2.9-arch1-1, sshd OpenSSH 10.6p1-2) |
| **Analyst** | Hayqal |
| **Event source** | SSH login attempts generated **from the host** to `127.0.0.1:2222` (QEMU hostfwd → guest port 22) |
| **Status** | Controlled simulation — not a real attack |
| **Rule** | [`../detections/ssh-brute-force.yml`](../detections/ssh-brute-force.yml) |
| **Raw evidence** | [`../evidence/journal-sshd-2026-10-17.log`](../evidence/journal-sshd-2026-10-17.log) (38 lines, `journalctl -o short-iso`) |

## 1. Summary

Nine SSH login attempts were sent from a single source within seconds:
six with nonexistent usernames, three with a valid user but the wrong key.
sshd recorded four failures, then **punished the source itself**
(`srclimit_penalise` — a 19.644 s penalty) and **dropped 8 connections**.
No successful authentication from that source during this window.

Key conclusion for detection engineering: **the logs are incomplete.**
The existing defense (OpenSSH `PerSourcePenalties`) cuts the attack short before
all attempts reach the authentication stage — so counting `Invalid user` lines
alone **undercounts** the attempts.

## 2. Environment

| Item | Value |
|---|---|
| Service | `sshd` OpenSSH 10.6p1-2, guest port 22 |
| Exposure | Only `127.0.0.1:2222` on the host (hostfwd, loopback) — not exposed to the LAN |
| Authentication | Keys only; `PermitRootLogin prohibit-password` |
| Logs | `systemd-journald`, **persistent** (`/var/log/journal`, 32 MB in use) |
| Source as seen by the guest | `10.0.2.2` (QEMU slirp gateway), not `127.0.0.1` |
| Related policy | `MaxAuthTries 6` · `PerSourcePenalties authfail:5s invaliduser:5s grace-exceeded:10s min:15s max:600s` · `PerSourcePenaltyExemptList none` |

## 3. Timeline (all +08)

| Time | Event |
|---|---|
| 09:42:30 | `Connection closed by authenticating user root 10.0.2.2 port 51640 [preauth]` — a root attempt **before** keys were installed |
| 09:44:00 | `Accepted publickey for hayqal …` — a valid SSH session (not the attacker) |
| 09:44:51 | `Invalid user admin … port 49986` → `Connection closed by invalid user … [preauth]` |
| 09:44:51 | `Invalid user root_test … port 49994` → closed |
| 09:44:51 | `Invalid user oracle … port 49998` → closed |
| 09:44:52 | `Invalid user ftpuser … port 50000` → closed |
| 09:44:52 | `srclimit_penalise: 10.0.2.2/32: activating ipv4 penalty of 19.644 seconds … attempted authentication by invalid user` |
| 09:44:52 | **6** lines of `drop connection … from [10.0.2.2] … on [10.0.2.15]:22 … penalty` (ports 50014–50066) |
| 09:45:02 | **2** more `drop connection … penalty` lines (ports 42410, 42418) |
| 09:46:23+ | `Accepted publickey for root …` — our own valid session after the penalty expired |

## 4. Evidence (verbatim; 38 full lines in the evidence file)

```
2026-10-17T09:44:51+08:00 arch-uji sshd-session[581]: Invalid user admin from 10.0.2.2 port 49986
2026-10-17T09:44:51+08:00 arch-uji sshd-session[581]: Connection closed by invalid user admin 10.0.2.2 port 49986 [preauth]
2026-10-17T09:44:51+08:00 arch-uji sshd-session[583]: Invalid user root_test from 10.0.2.2 port 49994
2026-10-17T09:44:51+08:00 arch-uji sshd-session[585]: Invalid user oracle from 10.0.2.2 port 49998
2026-10-17T09:44:52+08:00 arch-uji sshd-session[587]: Invalid user ftpuser from 10.0.2.2 port 50000
2026-10-17T09:44:52+08:00 arch-uji sshd[328]: srclimit_penalise: 10.0.2.2/32: activating ipv4 penalty of 19.644 seconds for penalty: attempted authentication by invalid user
2026-10-17T09:44:52+08:00 arch-uji sshd[328]: drop connection #0 from [10.0.2.2]:50014 on [10.0.2.15]:22 penalty: attempted authentication by invalid user
```

Counts from the evidence file:

| Pattern | Count |
|---|---|
| `Invalid user` | **4** (admin, root_test, oracle, ftpuser) |
| `drop connection … penalty` | **8** (6 at 09:44:52 + 2 at 09:45:02) |
| `srclimit_penalise` | 1 (19.644 s) |
| `Accepted` from that source | 5 — **all** `publickey` for `hayqal`/`root` (our own sessions, not the attacker) |

## 5. Analysis

1. **Pattern:** many different usernames from one source within ~2 s →
   brute force / user enumeration (MITRE **T1110.001**), not a targeted attack.
2. **Targeted account names:** `admin`, `root_test`, `oracle`, `ftpuser` — default
   service accounts; an automated scanner pattern, not a human.
3. **The defense acted on its own:** OpenSSH 10 ships `PerSourcePenalties` (active
   by default). The 19.644 s penalty > the 5 s base → it **grows** with frequency.
4. **Three "valid user + wrong key" attempts never appear as auth failures** —
   they appear as `drop connection … penalty`. This is direct proof that the
   penalty cuts attempts short **before** the authentication stage.
5. **The arithmetic does not match exactly:** 9 attempts sent, but 4 processed +
   8 dropped = 12 lines. The `ssh` client likely retried connections
   (one attempt → more than one connection). **Not yet confirmed** — the next
   step is to count TCP connections, not just log lines.
6. **No success from that source:** every `Accepted` is our own key
   (SHA256 `V+LYAN…`). No `Accepted password`, no unfamiliar new sessions.

## 6. The rule and how it was matched in practice

Rule: [`ssh-brute-force.yml`](../detections/ssh-brute-force.yml) — Sigma,
`selection | count() by src_ip > 5` within a 5-minute window.

No Sigma engine exists in this lab, so its logic was validated with an equivalent
query against the real logs:

```bash
journalctl -u sshd --since '-15 min' --no-pager -o cat \
  | grep -E 'Invalid user|Failed password|Failed publickey|Connection closed by authenticating|drop connection' \
  | grep -oE 'from (\[)?[0-9.]+' | sort | uniq -c | sort -rn
```

**Limitation:** `src_ip` is a *normalized* field (Wazuh/Elastic/Vector). Raw
journald has no such field — it must be extracted first. **This gap must be
closed by the OS log pipeline** before the rule can run in a real engine.

## 7. False positives / experimental limitations

- Authorized scanners, backup scripts with stale credentials, users repeatedly mistyping their password.
- One source only (`10.0.2.2`) — multi-IP attacks were not tested
  (which would evade `count() by src_ip`).
- Attempts were sent from the host, so the "attacker" always appears as the slirp gateway.
  Multi-source testing needs a bridge/`socket_vmnet` or a second VM.
- The `>5` threshold was chosen from common practice, **not** from 30 days of data on
  this machine.

## 8. Actions taken (SOC analyst role)

1. **Verify** the source: in this lab `10.0.2.2` = the host, so the activity was expected.
2. **Recount** using `drop connection` + `srclimit_penalise` lines so the attempt
   total is not undercounted.
3. **Check `Accepted`** from the same source after the penalty expired — if there is
   an unfamiliar session, escalate to a compromise incident.
4. **Block** the source at the network level (production: firewall/ACL) and
   **rotate** credentials if there is any sign of success.
5. **Tune the threshold:** `MaxAuthTries 6` means >5/5min may be too low for real
   users; a suggested 10/5min for small environments, validated with data.

## 9. Lessons for the OS (input to the design)

| Finding | Effect on the OS |
|---|---|
| journald is **not persistent** by default | The install script must `mkdir -p /var/log/journal` + a size cap |
| `hostname`/`ping` missing in a minimal install | Add `inetutils`/`iputils` or use `hostnamectl` |
| `PerSourcePenalties` active by default | The detector must count `drop connection`, not just `Invalid user` |
| A host-originated source is always `10.0.2.2` | Multi-source tests need a bridge/second VM, not user-mode NAT |
| The penalty blocked our own SSH | In the lab, set `PerSourcePenaltyExemptList` **only** during testing, and record that decision |

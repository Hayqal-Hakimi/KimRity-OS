#!/usr/bin/env python3
"""KimRity Security Gate — v2 (repo kod · web · server).

Satu tool yang memakai tool lain untuk menyemak sesuatu sasaran dan
mengeluarkan keputusan LULUS / LULUS BERSYARAT / TIDAK LULUS.

Penggunaan:
    gate.py <sasaran> [--kind repo|web|server] [--scope FAIL]
             [--authorized] [--out DIR] [--fail-on critical|high|medium] [--quiet]

    repo   : laluan folder/repo  → gitleaks + semgrep + trivy
    web    : URL (http/https)    → nuclei + nikto
    server : host / IP           → nmap (+ ssh-audit jika port 22 terbuka)

Imbasan aktif (web/server) WAJIB --authorized, dan jika --scope diberi,
sasaran mesti ada dalam fail skop itu.

Prinsip: model/AI tidak terlibat dalam keputusan. Verdict = peraturan kod.
"""

import argparse
import datetime
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from urllib.parse import urlparse

SEV_WEIGHT = {"critical": 4, "high": 3, "medium": 2, "low": 1, "info": 0, "unknown": 1}
SEV_ORDER = ["critical", "high", "medium", "low", "info", "unknown"]

# Gitleaks tidak memberi severity: rahsia terdedah sentiasa high.
SEMGREP_SEV = {"ERROR": "high", "WARNING": "medium", "INFO": "low"}

# Port yang lazimnya tidak sepatutnya terdedah pada antara muka rangkaian.
PORT_RISK = {
    21: "medium", 23: "high", 111: "low", 445: "high", 512: "high",
    513: "high", 514: "high", 1433: "high", 3306: "high", 3389: "medium",
    5432: "high", 5900: "medium", 6379: "high", 9200: "high", 27017: "high",
}

VERSION_CMD = {
    "gitleaks": ["gitleaks", "version"],
    "semgrep": ["semgrep", "--version"],
    "trivy": ["trivy", "--version"],
    "nuclei": ["nuclei", "-version"],
    "nikto": ["nikto", "-Version"],
    "nmap": ["nmap", "--version"],
    "ssh-audit": ["ssh-audit", "--version"],
}


def run(cmd, timeout=1800):
    """Jalankan arahan; pulangkan (returncode, stdout, stderr)."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except FileNotFoundError:
        return 127, "", f"tool tidak dijumpai: {cmd[0]}"
    except subprocess.TimeoutExpired:
        return 124, "", f"tamat masa selepas {timeout}s: {' '.join(cmd[:3])}"


def tool_version(name):
    """Ada binari = alat tersedia. Versi diambil secara best-effort —
    sesetengah alat (cth ssh-audit) tiada flag --version."""
    if shutil.which(name) is None:
        return None
    rc, out, err = run(VERSION_CMD[name], timeout=120)
    text = ((out or "") + "\n" + (err or "")).strip().splitlines()
    return text[0].strip() if text else "?"


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def finding(tool, rule, severity, target, message, fix="", line=0):
    return {"tool": tool, "rule": rule, "severity": severity,
            "file": target, "line": line,
            "message": message[:300], "fix": (fix or "")[:300]}


# ---------------------------------------------------------------- repo

def scan_gitleaks(repo, tmp):
    out = os.path.join(tmp, "gitleaks.json")
    mode = "git" if os.path.isdir(os.path.join(repo, ".git")) else "dir"
    cmd = ["gitleaks", mode, repo, "--report-format", "json",
           "--report-path", out, "--exit-code", "0", "--no-banner"]
    rc, _, err = run(cmd)
    data = read_json(out)
    if data is None:
        return [], f"gitleaks gagal (rc={rc}): {err.strip()[:300]}"
    out_findings = []
    for f in data if isinstance(data, list) else []:
        out_findings.append(finding(
            "gitleaks", f.get("RuleID", "?"), "high",
            f.get("File", "?"), f.get("Description", "rahsia terdedah"),
            "buang rahsia dari kod dan sejarah git; putar semula kunci",
            f.get("StartLine", 0) or 0))
    return out_findings, None


def scan_semgrep(repo, tmp):
    out = os.path.join(tmp, "semgrep.json")
    cmd = ["semgrep", "--config", "p/default", "--json", "--output", out,
           "--quiet", "--metrics", "off", "--disable-version-check", repo]
    rc, _, err = run(cmd)
    data = read_json(out)
    if data is None:
        return [], f"semgrep gagal (rc={rc}): {err.strip()[:300]}"
    out_findings = []
    for r in data.get("results", []):
        extra = r.get("extra", {})
        out_findings.append(finding(
            "semgrep", r.get("check_id", "?"),
            SEMGREP_SEV.get(str(extra.get("severity", "")).upper(), "unknown"),
            os.path.relpath(r.get("path", "?"), repo),
            extra.get("message", "").strip(),
            (extra.get("metadata", {}) or {}).get("fix", "")
            or "semak corak dan betulkan mengikut nasihat rule",
            r.get("start", {}).get("line", 0)))
    errors = data.get("errors") or []
    if not out_findings and errors:
        return [], (f"semgrep: {len(errors)} ralat, tiada hasil "
                    f"(cth: {errors[0].get('message', '')[:200]})")
    return out_findings, None


def scan_trivy(repo, tmp):
    out = os.path.join(tmp, "trivy.json")
    cmd = ["trivy", "fs", "--format", "json", "--output", out,
           "--scanners", "vuln,secret,misconfig", "--quiet",
           "--skip-version-check", repo]
    rc, _, err = run(cmd)
    data = read_json(out)
    if data is None:
        return [], f"trivy gagal (rc={rc}): {err.strip()[:300]}"
    out_findings = []
    for res in data.get("Results", []) or []:
        tgt = res.get("Target", "?")
        for v in res.get("Vulnerabilities", []) or []:
            out_findings.append(finding(
                "trivy", v.get("VulnerabilityID", "?"),
                str(v.get("Severity", "unknown")).lower(), tgt,
                f"{v.get('PkgName', '?')} {v.get('InstalledVersion', '?')}: {v.get('Title', 'CVE')}",
                f"naik taraf ke {v.get('FixedVersion')}" if v.get("FixedVersion")
                else "tiada versi pembaikan dilaporkan"))
        for s in res.get("Secrets", []) or []:
            out_findings.append(finding(
                "trivy", s.get("RuleID", "secret"), "high", tgt,
                s.get("Title", "rahsia terdedah"),
                "buang dan putar semula kunci", s.get("StartLine", 0) or 0))
        for m in res.get("Misconfigurations", []) or []:
            if str(m.get("Status", "")).upper() == "PASS":
                continue
            out_findings.append(finding(
                "trivy", m.get("ID", "?"),
                str(m.get("Severity", "unknown")).lower(), tgt,
                m.get("Title") or "", m.get("Resolution") or "",
                (m.get("CauseMetadata", {}) or {}).get("StartLine", 0) or 0))
    return out_findings, None


# ----------------------------------------------------------------- web

def scan_nuclei(url, tmp):
    out = os.path.join(tmp, "nuclei.jsonl")
    cmd = ["nuclei", "-u", url, "-jsonl", "-o", out, "-silent", "-no-color",
           "-severity", "critical,high,medium", "-etags", "intrusive,dos,fuzz",
           "-timeout", "10", "-retries", "1"]
    rc, _, err = run(cmd, timeout=1800)
    if not os.path.exists(out):
        return [], f"nuclei gagal (rc={rc}): {err.strip()[:300]}"
    out_findings = []
    with open(out, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            info = d.get("info", {}) or {}
            out_findings.append(finding(
                "nuclei", d.get("template-id", "?"),
                str(info.get("severity", "unknown")).lower(),
                d.get("matched-at") or d.get("host") or url,
                info.get("name") or "",
                info.get("remediation") or "semak template dan betulkan"))
    return out_findings, None


def scan_nikto(url, tmp):
    out = os.path.join(tmp, "nikto.json")
    cmd = ["nikto", "-h", url, "-Format", "json", "-output", out,
           "-nointeractive", "-ask", "no", "-maxtime", "10m"]
    rc, _, err = run(cmd, timeout=900)
    data = read_json(out)
    if data is None:
        return [], f"nikto gagal (rc={rc}): {err.strip()[:200]}"
    out_findings = []
    hosts = data if isinstance(data, list) else [data]
    for h in hosts:
        for v in h.get("vulnerabilities", []) or []:
            msg = v.get("msg") or ""
            sev = "low" if "Suggested security header" in msg else "medium"
            out_findings.append(finding(
                "nikto", str(v.get("id", "?")), sev,
                (h.get("host") or url) + (v.get("url") or ""), msg,
                "semak penemuan nikto dan betulkan konfigurasi pelayan"))
    return out_findings, None


# -------------------------------------------------------------- server

def scan_nmap(host, tmp):
    out = os.path.join(tmp, "nmap.xml")
    cmd = ["nmap", "-sV", "-Pn", "-T4", "--top-ports", "1000",
           "--script", "banner,ssh2-enum-algos,ssl-enum-ciphers,http-title",
           "-oX", out, host]
    rc, _, err = run(cmd, timeout=1800)
    if not os.path.exists(out):
        return [], f"nmap gagal (rc={rc}): {err.strip()[:300]}", set()
    try:
        root = ET.parse(out).getroot()
    except ET.ParseError as e:
        return [], f"nmap XML tak sah: {e}", set()

    out_findings, open_ports = [], set()
    for h in root.findall("host"):
        for port in h.findall("./ports/port"):
            state = port.find("state")
            if state is None or state.get("state") != "open":
                continue
            num = int(port.get("portid"))
            open_ports.add(num)
            svc = port.find("service")
            svc_name = svc.get("name", "?") if svc is not None else "?"
            product = svc.get("product", "") if svc is not None else ""
            version = svc.get("version", "") if svc is not None else ""
            label = f"{num}/{port.get('protocol', 'tcp')} {svc_name} {product} {version}".strip()
            sev = PORT_RISK.get(num)
            if sev:
                out_findings.append(finding(
                    "nmap", f"port-{num}", sev, host, f"Port {label} terdedah",
                    "tutup port atau hadkan kepada rangkaian yang perlu"))
            for sc in port.findall("script"):
                sid = sc.get("id", "")
                text = (sc.get("output") or "").strip()
                if not text:
                    continue
                low = text.lower()
                if sid == "ssh2-enum-algos" and ("ssh-rsa" in low or "group1-sha1" in low):
                    out_findings.append(finding(
                        "nmap", "ssh-weak-algo", "medium", host,
                        f"SSH {num} menawarkan algoritma lemah (ssh-rsa / group1-sha1)",
                        "larang algoritma SHA-1 dalam sshd_config"))
                if sid == "ssl-enum-ciphers":
                    if "sslv3" in low:
                        out_findings.append(finding(
                            "nmap", "ssl-sslv3", "high", host,
                            f"SSLv3 aktif pada port {num}", "lumpuhkan SSLv3"))
                    elif "tlsv1.0" in low or "tlsv1.1" in low:
                        out_findings.append(finding(
                            "nmap", "ssl-legacy", "medium", host,
                            f"TLS 1.0/1.1 aktif pada port {num}", "lumpuhkan TLS 1.0/1.1"))
    return out_findings, None, open_ports


def scan_sshaudit(host, tmp):
    """ssh-audit keluar 0 (selamat) atau 3 (ada fail/warn) — bukan ralat.

    Pelarasan (didokumen dalam README): dua kategori dalam ssh-audit ialah
    pendapat/anjuran, bukan kerosakan sebenar —
      • 'suspected as being backdoored' (kiraan NIST curves) → low
      • 'post-quantum' (persediaan masa depan)                → info
    [fail] lain (cth SHA-1 rosak) kekal high.
    """
    rc, out, err = run(["ssh-audit", host], timeout=300)
    if not out.strip():
        return [], f"ssh-audit gagal (rc={rc}): {err.strip()[:200]}"
    out_findings = []
    for line in out.splitlines():
        s = line.strip()
        if "suspected as being backdoored" in s:
            sev, rule = "low", "ssh-curve-opinion"
        elif "post-quantum" in s:
            sev, rule = "info", "ssh-pq-advisory"
        elif "[fail]" in s:
            sev, rule = "high", "ssh-fail"
        elif "[warn]" in s:
            sev, rule = "medium", "ssh-warn"
        else:
            continue
        out_findings.append(finding("ssh-audit", rule, sev, host, s,
                                    "betulkan mengikut cadangan ssh-audit"))
    return out_findings, None


# ------------------------------------------------------------- skop

def host_of(target):
    p = urlparse(target if "://" in target else "//" + target)
    return (p.hostname or target).lower()


def scope_allows(scope_file, target):
    host = host_of(target)
    try:
        with open(scope_file, encoding="utf-8") as fh:
            entries = [ln.strip() for ln in fh
                       if ln.strip() and not ln.strip().startswith("#")]
    except OSError as e:
        sys.exit(f"ralat: fail skop tidak boleh dibaca: {e}")

    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        ip = None

    for e in entries:
        if e.startswith("http://") or e.startswith("https://"):
            e_host = host_of(e)
        else:
            e_host = e.split("/")[0].split(":")[0].lower()
        if ip is not None:
            try:
                if ip in ipaddress.ip_network(e, strict=False):
                    return True
            except ValueError:
                pass
        if host == e_host or host.endswith("." + e_host):
            return True
    return False


def auto_kind(target):
    if os.path.isdir(target):
        return "repo"
    if target.startswith(("http://", "https://")):
        return "web"
    if re.match(r"^[A-Za-z0-9_.\-]+(:\d+)?$", target):
        return "server"
    sys.exit(f"ralat: tidak dapat tentukan jenis sasaran: {target} (guna --kind)")


# ------------------------------------------------------------ verdict

def verdict_of(findings, tool_errors, fail_on):
    if tool_errors:
        return "TIDAK LULUS", "tool gagal dijalankan — tiada bukti, tiada kelulusan"
    counts = {s: 0 for s in SEV_ORDER}
    for f in findings:
        counts[f["severity"]] = counts.get(f["severity"], 0) + 1
    threshold = SEV_WEIGHT[fail_on]
    worst = max((SEV_WEIGHT[f["severity"]] for f in findings), default=-1)
    if worst >= threshold:
        return "TIDAK LULUS", f"ada isu {fail_on} atau lebih teruk"
    if counts["medium"]:
        return "LULUS BERSYARAT", "tiada isu kritikal/high, tetapi ada medium"
    return "LULUS", "tiada isu melepasi ambang"


def git_commit(repo):
    rc, out, _ = run(["git", "-C", repo, "rev-parse", "--short", "HEAD"], timeout=30)
    return out.strip() if rc == 0 else None


def write_report(path, result):
    c = result["counts"]
    meta = result["meta"]
    lines = [
        "# Laporan Security Gate",
        "",
        f"**Sasaran:** `{meta['target']}`  ",
        f"**Jenis:** {meta['kind']}  ",
    ]
    if meta.get("commit"):
        lines.append(f"**Commit:** `{meta['commit']}`  ")
    if meta.get("scope"):
        lines.append(f"**Fail skop:** `{meta['scope']}`  ")
    lines += [
        f"**Masa:** {meta['timestamp']}  ",
        f"**Verdict:** **{result['verdict']}** — {result['reason']}",
        "",
        "## Kiraan isu",
        "",
        "| Tahap | Bilangan |",
        "|---|---|",
    ]
    for s in SEV_ORDER:
        if c.get(s):
            lines.append(f"| {s} | {c[s]} |")
    if not any(c.values()):
        lines.append("| — | 0 |")

    lines += ["", "## Alat", "", "| Alat | Versi | Status |", "|---|---|---|"]
    for name, ver in meta["tools"].items():
        status = "OK" if name not in result["tool_errors"] else "GAGAL"
        lines.append(f"| {name} | {ver or '-'} | {status} |")
    for name, err in result["tool_errors"].items():
        lines.append(f"\n> {name}: {err}")

    top = sorted(result["findings"], key=lambda f: SEV_WEIGHT[f["severity"]], reverse=True)[:25]
    if top:
        lines += ["", "## Isu utama", "",
                  "| Tahap | Alat | Sasaran:baris | Isu | Pembaikan |",
                  "|---|---|---|---|---|"]
        for f in top:
            loc = f"{f['file']}:{f['line']}" if f["line"] else f["file"]
            msg = f["message"].replace("|", "/")[:120]
            fix = (f["fix"] or "-").replace("|", "/")[:100]
            lines.append(f"| {f['severity']} | {f['tool']} | `{loc}` | {msg} | {fix} |")
        if len(result["findings"]) > len(top):
            lines.append(f"\n*{len(result['findings']) - len(top)} isu lagi dalam gate.json.*")
    else:
        lines += ["", "_Tiada isu dilaporkan._"]

    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser(description="KimRity Security Gate v2")
    ap.add_argument("target", help="repo/folder, URL, atau host/IP")
    ap.add_argument("--kind", choices=["repo", "web", "server"], default=None)
    ap.add_argument("--scope", default=None, help="fail senarai sasaran dibenarkan")
    ap.add_argument("--authorized", action="store_true",
                    help="sahkan kau ada kebenaran menyasar (wajib untuk web/server)")
    ap.add_argument("--out", default="gate-out", help="folder keluaran (lalai: ./gate-out)")
    ap.add_argument("--fail-on", default="high", choices=["critical", "high", "medium"],
                    help="ambang TIDAK LULUS (lalai: high)")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    kind = args.kind or auto_kind(args.target)
    target = os.path.abspath(args.target) if kind == "repo" else args.target

    if kind == "repo" and not os.path.isdir(target):
        sys.exit(f"ralat: bukan folder: {target}")
    if kind in ("web", "server") and not args.authorized:
        sys.exit("ralat: imbasan aktif perlukan --authorized "
                 "(kau sahkan kau ada kebenaran menyasar sasaran ini)")
    if args.scope and not scope_allows(args.scope, target):
        sys.exit(f"ralat: sasaran {host_of(target)} tiada dalam fail skop {args.scope}")

    os.makedirs(args.out, exist_ok=True)
    tmp = os.path.join(args.out, ".raw")
    os.makedirs(tmp, exist_ok=True)

    versions, findings, tool_errors = {}, [], {}

    def do(name, fn, *a):
        if not args.quiet:
            print(f"[gate] {name} ...", flush=True)
        versions[name] = tool_version(name)
        if versions[name] is None:
            tool_errors[name] = "tool tidak dipasang atau tidak boleh dijalankan"
            return None
        res = fn(*a)
        findings.extend(res[0])
        err = res[1] if len(res) > 1 else None
        if err:
            tool_errors[name] = err
        return res[2] if len(res) > 2 else None

    commit = None
    if kind == "repo":
        do("gitleaks", scan_gitleaks, target, tmp)
        do("semgrep", scan_semgrep, target, tmp)
        do("trivy", scan_trivy, target, tmp)
        commit = git_commit(target)
    elif kind == "web":
        do("nuclei", scan_nuclei, target, tmp)
        do("nikto", scan_nikto, target, tmp)
    else:
        host = host_of(target)
        open_ports = do("nmap", scan_nmap, host, tmp) or set()
        # ssh-audit hanya jika port 22 terbuka (atau nmap gagal → cuba juga)
        if 22 in open_ports or "nmap" in tool_errors:
            do("ssh-audit", scan_sshaudit, host, tmp)

    verdict, reason = verdict_of(findings, tool_errors, args.fail_on)
    counts = {s: 0 for s in SEV_ORDER}
    for f in findings:
        counts[f["severity"]] = counts.get(f["severity"], 0) + 1

    result = {
        "meta": {
            "gate": "kimrity-security-gate/2",
            "kind": kind,
            "target": target,
            "commit": commit,
            "scope": args.scope,
            "timestamp": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
            "fail_on": args.fail_on,
            "tools": versions,
        },
        "verdict": verdict,
        "reason": reason,
        "counts": counts,
        "tool_errors": tool_errors,
        "findings": findings,
    }

    json_path = os.path.join(args.out, "gate.json")
    md_path = os.path.join(args.out, "laporan.md")
    with open(json_path, "w", encoding="utf-8") as fh:
        json.dump(result, fh, ensure_ascii=False, indent=2)
    write_report(md_path, result)

    print(f"[gate] {verdict} — {reason}")
    print(f"[gate] {len(findings)} isu | bukti: {json_path} | laporan: {md_path}")
    sys.exit(0 if verdict in ("LULUS", "LULUS BERSYARAT") else 1)


if __name__ == "__main__":
    main()

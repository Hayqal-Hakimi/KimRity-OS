// ~/.config/quickshell/kimrity/shell.qml
// Menu KimRity v4: popup 900x560 — sidebar, 3 kluster workspace, app 2 lajur,
// recent files + notes. Flat, tiada hiasan.
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import Quickshell.Io

ShellRoot {
    id: root

    property bool isOpen: false
    property int catIndex: -1      // -1 = semua
    property int appIndex: 0
    property int wsIndex: 0
    property string filter: ""

    // Kluster workspace — dibina daripada conf pengguna (kimrity-ws) dan
    // ikon sebenar (kimrity-icons). Tiada tool/glyph hardcoded di sini.
    property var clusters: []
    property var iconMap: ({})
    property string wsText: ""
    property bool wsDone: false
    property bool iconsDone: false
    property bool wsMutating: false

    onIsOpenChanged: if (isOpen) {
        root.refreshClusters()
        root.refreshNotes()
        if (root.gatePage) root.refreshGateHistory()
    }
    Component.onCompleted: { root.refreshClusters(); root.refreshNotes(); root.loadApps() }

    // Aplikasi sebenar daripada kimrity-apps:
    //   name <TAB> iconpath <TAB> cmd <TAB> cat <TAB> id
    property var appData: []
    property bool appsLoaded: false
    readonly property var apps: {
        const q = root.filter.trim().toLowerCase()
        if (q.length === 0) return root.appData
        return root.appData.filter(a => String(a.name || "").toLowerCase().includes(q))
    }

    readonly property var recent: [
        { n: "report-gate-2026-10.md", p: "~/Documents/kimrity · 20:41" },
        { n: "hyprland.conf",          p: "~/.config/hypr · 20:32" },
        { n: "audit.log",              p: "/var/log/audit · 18:04" },
        { n: "shell.qml",              p: "~/.config/quickshell/kimrity · 19:57" }
    ]

    // ---------------- seting preset ----------------
    property bool setOpen: false
    property string editPreset: ""
    property var editRows: []
    property int newWs: 1
    property var tools: []
    property var toolHits: []
    readonly property string homeDir: Quickshell.env("HOME") || "/home/hayqal"
    readonly property string confPath: homeDir + "/.config/kimrity/workspaces.conf"

    // ---------------- nota ----------------
    // Nota disimpan dalam JSON dan dibaca semula melalui Process + StdioCollector.
    property var notes: []
    property bool notesDone: false
    property int noteIndex: -1
    property bool noteEdit: false
    property bool notesMenuOpen: false
    property bool pendingNoteEdit: false
    readonly property string notesPath: homeDir + "/.config/kimrity/notes.json"

    // ---------------- gate ----------------
    // Halaman Gate: pilih sasaran, jalankan kimrity-gate (NDJSON), baca
    // gate.json sebenar. Tiada analisis AI dalam versi ini.
    property bool gatePage: false
    property string gateKind: "repo"
    property string gateTarget: ""
    property bool gateAuthorized: false
    property bool gateRunning: false
    property bool gateDone: false
    property string gateVerdict: ""
    property string gateReason: ""
    property string gateError: ""
    property var gateCounts: ({})
    property var gateFindings: []
    property var gateScanners: []
    property var gateToolErrors: ({})
    property string gateLoadedJson: ""
    property string gateJsonPending: ""
    property var gateHistory: []
    property bool gateHistoryLoading: false
    readonly property string gateHistoryDir: homeDir + "/.local/share/kimrity/gate"
    readonly property bool gateCanRun: root.gateTarget.trim().length > 0
        && !root.gateRunning
        && (root.gateKind === "repo" || root.gateAuthorized)

    // Logik JSON inline: jq jika ada, python3 jika tiada.
    readonly property string notesScript: `
set -u
f="$1"; op="$2"; id="$3"; shift 3 || true; text="$*"
mkdir -p "$(dirname "$f")"
[ -s "$f" ] || printf '%s\n' '[]' > "$f"
if command -v jq >/dev/null 2>&1; then
  case "$op" in
    add)
      tmp=$(mktemp) && jq --arg id "$id" --arg t "$text" '. + [{id:$id, type:"note", text:$t, done:false}]' "$f" > "$tmp" && mv -- "$tmp" "$f" ;;
    addcheck)
      tmp=$(mktemp) && jq --arg id "$id" --arg t "$text" '. + [{id:$id, type:"check", text:$t, done:false}]' "$f" > "$tmp" && mv -- "$tmp" "$f" ;;
    toggle)
      tmp=$(mktemp) && jq --arg id "$id" 'map(if .id == $id then .done = (.done | not) else . end)' "$f" > "$tmp" && mv -- "$tmp" "$f" ;;
    edit)
      tmp=$(mktemp) && jq --arg id "$id" --arg t "$text" 'map(if .id == $id then .text = $t else . end)' "$f" > "$tmp" && mv -- "$tmp" "$f" ;;
    del)
      tmp=$(mktemp) && jq --arg id "$id" 'map(select(.id != $id))' "$f" > "$tmp" && mv -- "$tmp" "$f" ;;
  esac
  jq -c . "$f" 2>/dev/null || printf '%s\n' '[]'
else
  python3 - "$f" "$op" "$id" "$text" <<'PY'
import json, sys
f, op, i, t = sys.argv[1:5]
try:
    with open(f) as fh:
        data = json.load(fh)
except Exception:
    data = []
if not isinstance(data, list):
    data = []
if op == 'add':
    data.append({"id": i, "type": "note", "text": t, "done": False})
elif op == 'addcheck':
    data.append({"id": i, "type": "check", "text": t, "done": False})
elif op == 'toggle':
    for n in data:
        if n.get('id') == i:
            n['done'] = not n.get('done', False)
elif op == 'edit':
    for n in data:
        if n.get('id') == i:
            n['text'] = t
elif op == 'del':
    data = [n for n in data if n.get('id') != i]
with open(f, 'w') as fh:
    json.dump(data, fh)
print(json.dumps(data))
PY
fi
`

    // Skrip cetak fail penuh ke stdout; UI baca dari situ (tiada cache).
    Process {
        id: wsRunner
        stdout: StdioCollector {
            id: wsOut
            onStreamFinished: root.applyRows(wsOut.text)
        }
        onExited: {
            if (root.wsMutating) {
                root.wsMutating = false
                root.refreshClusters()
            }
        }
    }

    // Conf penuh untuk kluster (bukan editor). kimrity-ws perlukan argumen
    // preset walaupun untuk `list`; `list` mengabaikannya dan cetak semua baris.
    Process {
        id: wsListProc
        stdout: StdioCollector {
            id: wsListOut
            onStreamFinished: root.wsListReady(wsListOut.text)
        }
        onExited: if (!root.wsDone) root.wsListReady("")
    }

    // Peta tool -> laluan ikon sebenar.
    Process {
        id: iconsProc
        stdout: StdioCollector {
            id: iconsOut
            onStreamFinished: root.iconsReady(iconsOut.text)
        }
        onExited: if (!root.iconsDone) root.iconsReady("")
    }

    // Senarai tool yang benar-benar ada (cache 1 hari) untuk dropdown.
    Process {
        id: toolsProc
        stdout: StdioCollector {
            id: toolsOut
            onStreamFinished: {
                const t = (toolsOut.text || "").split("\n").filter(s => s.length > 0)
                root.tools = t
            }
        }
    }

    // Senarai aplikasi sebenar (sekali sahaja). Skrip mungkin belum wujud;
    // jika tiada output, senarai kekal kosong tanpa ralat QML.
    Process {
        id: appsProc
        stdout: StdioCollector {
            id: appsOut
            onStreamFinished: root.appsReady(appsOut.text)
        }
    }

    // Semua operasi nota cetak semula JSON penuh; sama seperti kimrity-ws.
    Process {
        id: notesProc
        stdout: StdioCollector {
            id: notesOut
            onStreamFinished: root.notesReady(notesOut.text)
        }
        onExited: if (!root.notesDone) root.notesReady("[]")
    }

    // Gate: SplitParser membaca NDJSON baris demi baris semasa proses hidup
    // supaya status scanner boleh dikemas kini. gate.json dibaca berasingan
    // melalui Process + StdioCollector (tiada cache FileView).
    Process {
        id: gateRunProc
        stdout: SplitParser {
            onRead: (line) => root.gateLine(line)
        }
        onExited: (code, status) => root.gateExited(code)
    }

    Process {
        id: gateJsonProc
        stdout: StdioCollector {
            id: gateJsonOut
            onStreamFinished: root.gateJsonReady(gateJsonOut.text)
        }
        onExited: {
            if (gateJsonOut.text.length === 0) root.gateJsonReady("")
        }
    }

    Process {
        id: gateHistoryProc
        stdout: StdioCollector {
            id: gateHistoryOut
            onStreamFinished: root.gateHistoryReady(gateHistoryOut.text)
        }
        onExited: if (root.gateHistoryLoading) root.gateHistoryReady("")
    }

    function loadTools() {
        if (root.tools.length > 0) return
        toolsProc.command = [root.homeDir + "/.local/bin/kimrity-tools"]
        toolsProc.running = true
    }

    function loadApps() {
        if (root.appsLoaded) return
        root.appsLoaded = true
        // Skrip mungkin belum wujud: jangan bunyi bising, pulangkan output kosong.
        appsProc.command = ["bash", "-lc",
            "f=\"$1\"; [ -x \"$f\" ] && exec \"$f\" || exit 0",
            "kimrity-apps", root.homeDir + "/.local/bin/kimrity-apps"]
        appsProc.running = true
    }

    function appsReady(t) {
        const out = []
        for (const line of (t || "").split("\n")) {
            if (line.length === 0) continue
            const p = line.split("\t")
            if (p.length < 3) continue
            const name = (p[0] || "").trim()
            if (name.length === 0) continue
            let icon = (p[1] || "").trim()
            if (icon === "--") icon = ""
            out.push({
                name: name,
                icon: icon,
                cmd: (p[2] || "").trim(),
                cat: (p[3] || "").trim(),
                id: (p[4] || "").trim()
            })
        }
        root.appData = out
    }

    // ---------------- nota ----------------
    function refreshNotes() {
        root.notesCall("read", "", "")
    }

    function notesCall(op, id, text) {
        root.notesDone = false
        notesProc.command = ["bash", "-lc", root.notesScript, "kimrity-notes",
                             root.notesPath, op, id || "", text || ""]
        notesProc.running = true
    }

    function notesReady(t) {
        root.notesDone = true
        let v = []
        try {
            v = JSON.parse((t || "").trim() || "[]")
        } catch (e) {
            v = []
        }
        root.notes = Array.isArray(v) ? v : []
        if (root.noteIndex >= root.notes.length) root.noteIndex = root.notes.length - 1
        if (root.pendingNoteEdit && root.notes.length > 0) {
            root.pendingNoteEdit = false
            root.noteIndex = root.notes.length - 1
            root.noteEdit = true
        }
    }

    function addNote(kind) {
        const id = "n" + Date.now().toString(36) + Math.random().toString(36).slice(2, 7)
        root.notesMenuOpen = false
        root.pendingNoteEdit = true
        root.notesCall(kind === "check" ? "addcheck" : "add", id, "")
    }

    function toggleNote(id) {
        root.notesCall("toggle", id, "")
    }

    function commitNote(id, text) {
        const s = (text || "").trim()
        root.noteEdit = false
        if (s.length === 0) root.notesCall("del", id, "")
        else root.notesCall("edit", id, s)
    }

    function deleteNote(id) {
        root.notesMenuOpen = false
        root.noteEdit = false
        root.notesCall("del", id, "")
    }

    function notesMenuAction(act) {
        if (act === "note") { root.addNote("note"); return }
        if (act === "check") { root.addNote("check"); return }
        const n = root.notes[root.noteIndex]
        if (!n) { root.notesMenuOpen = false; return }
        if (act === "edit") {
            root.notesMenuOpen = false
            root.noteEdit = true
        } else if (act === "del") {
            root.deleteNote(n.id)
        }
    }

    function updateHits(q) {
        const s = (q || "").toLowerCase()
        if (s.length === 0) { root.toolHits = []; return }
        const out = []
        for (let i = 0; i < root.tools.length && out.length < 8; i++) {
            if (root.tools[i].toLowerCase().startsWith(s)) out.push(root.tools[i])
        }
        root.toolHits = out
    }

    // ---------------- gate ----------------
    function gateCount(name) {
        const c = root.gateCounts || {}
        const n = c[name]
        return typeof n === "number" ? n : 0
    }

    function gateSevColor(s) {
        const v = String(s || "").toLowerCase()
        if (v === "critical" || v === "high") return "#e8443a"
        if (v === "medium") return "#e0a34a"
        if (v === "low") return "#5aa9e6"
        return "#7d8aa8"
    }

    function gateVerdictColor(v) {
        const s = String(v || "")
        if (s === "LULUS") return "#3fbf8f"
        if (s === "LULUS BERSYARAT" || s === "BERSYARAT") return "#e0a34a"
        if (s === "TIDAK LULUS") return "#e8443a"
        return "#5b6784"
    }

    function gateVerdictLabel(v) {
        const s = String(v || "")
        if (s === "LULUS BERSYARAT") return "BERSYARAT"
        return s
    }

    function gateLocation(f) {
        if (!f) return ""
        const file = String(f.file || "?")
        const line = parseInt(f.line)
        return isNaN(line) || line <= 0 ? file : file + ":" + line
    }

    function gateUpsertScanner(name, status, reason) {
        const n = String(name || "gate")
        const arr = root.gateScanners.slice()
        const row = { name: n, status: String(status || "running"), reason: String(reason || "") }
        for (let i = 0; i < arr.length; i++) {
            if (arr[i].name === n) {
                arr[i] = row
                root.gateScanners = arr
                return
            }
        }
        arr.push(row)
        root.gateScanners = arr
    }

    function gateLine(line) {
        const s = (line || "").trim()
        if (s.length === 0) return
        let o = null
        try { o = JSON.parse(s) } catch (e) { return }
        if (!o || typeof o !== "object") return

        if (o.phase === "start") {
            root.gateLoadedJson = String(o.out || "")
            return
        }
        if (o.phase === "scanner") {
            root.gateUpsertScanner(o.name, o.status, o.reason)
            return
        }
        if (o.phase === "error") {
            root.gateError = String(o.message || "ralat gate")
            root.gateRunning = false
            return
        }
        if (o.phase === "done") {
            root.gateRunning = false
            root.gateDone = true
            root.gateVerdict = String(o.verdict || "")
            root.gateCounts = o.counts || ({})
            root.gateReason = String(o.reason || "")
            if (o.json) root.loadGateJson(String(o.json))
            else if (o.out) root.loadGateJson(String(o.out) + "/gate.json")
            root.refreshGateHistory()
        }
    }

    function startGate() {
        if (!root.gateCanRun) return
        root.gateRunning = true
        root.gateDone = false
        root.gateError = ""
        root.gateVerdict = ""
        root.gateReason = ""
        root.gateCounts = ({})
        root.gateFindings = []
        root.gateScanners = []
        root.gateToolErrors = ({})
        root.gateLoadedJson = ""

        const wrapper = root.homeDir + "/.local/bin/kimrity-gate"
        const args = ["bash", "-lc", "exec \"$@\"", "kimrity-gate", wrapper,
                      root.gateKind, root.gateTarget.trim()]
        if (root.gateAuthorized) args.push("authorized")
        gateRunProc.command = args
        gateRunProc.running = true
    }

    function gateExited(code) {
        if (!root.gateRunning) return
        root.gateRunning = false
        if (!root.gateDone && root.gateError === "")
            root.gateError = "Scan berhenti (exit " + code + ")"
    }

    function loadGateJson(path) {
        if (!path) return
        root.gateJsonPending = path
        gateJsonProc.command = ["bash", "-lc", "cat -- \"$1\"", "gatecat", path]
        gateJsonProc.running = true
    }

    function gateJsonReady(t) {
        const path = root.gateJsonPending
        root.gateJsonPending = ""
        let j = null
        try { j = JSON.parse((t || "").trim()) } catch (e) { j = null }
        if (!j || typeof j !== "object") {
            root.gateError = path ? ("gate.json tidak dapat dibaca: " + path) : "gate.json tidak dapat dibaca"
            if (!root.gateDone) root.gateRunning = false
            return
        }
        root.gateLoadedJson = path
        root.gateVerdict = String(j.verdict || "")
        root.gateReason = String(j.reason || "")
        root.gateCounts = j.counts || ({})
        root.gateFindings = Array.isArray(j.findings) ? j.findings : []
        root.gateToolErrors = j.tool_errors || ({})
        root.gateDone = true
        root.gateRunning = false
        root.gateError = ""
        if (j.meta) {
            if (j.meta.kind) root.gateKind = String(j.meta.kind)
            if (j.meta.target) root.gateTarget = String(j.meta.target)
        }
    }

    function refreshGateHistory() {
        root.gateHistoryLoading = true
        gateHistoryProc.command = ["bash", "-lc",
            "d=\"$1\"; [ -d \"$d\" ] || exit 0; for p in \"$d\"/*/; do [ -f \"$p/gate.json\" ] && basename \"$p\"; done | sort -r | head -n 5",
            "gatehist", root.gateHistoryDir]
        gateHistoryProc.running = true
    }

    function gateHistoryReady(t) {
        root.gateHistoryLoading = false
        const out = []
        for (const line of (t || "").split("\n")) {
            const s = line.trim()
            if (s.length > 0) out.push(s)
        }
        root.gateHistory = out
    }

    function loadGateHistory(name) {
        const dir = root.gateHistoryDir + "/" + name
        root.gateRunning = false
        root.gateDone = false
        root.gateError = ""
        root.gateVerdict = ""
        root.gateReason = ""
        root.gateCounts = ({})
        root.gateFindings = []
        root.gateScanners = []
        root.gateToolErrors = ({})
        root.gateLoadedJson = ""
        root.loadGateJson(dir + "/gate.json")
    }

    function applyRows(t) {
        if (root.editPreset === "") { root.editRows = []; return }
        const out = []
        for (const line of (t || "").split("\n")) {
            if (!line.startsWith(root.editPreset + "|")) continue
            const p = line.split("|")
            if (p.length < 5) continue
            const w = parseInt(p[2])
            out.push({ label: p[1], ws: isNaN(w) ? 1 : w, tool: p[3], args: p.slice(4).join("|") })
        }
        root.editRows = out
    }

    function wsCall(args) {
        root.wsMutating = args[0] !== "list"
        wsRunner.command = [root.homeDir + "/.local/bin/kimrity-ws"].concat(args)
        wsRunner.running = true
    }

    // Muat semula kluster + ikon. Dipanggil semasa buka menu, selepas edit,
    // dan selepas apply supaya panel tidak tunjuk data basi.
    function refreshClusters() {
        root.wsText = ""
        root.iconMap = ({})
        root.wsDone = false
        root.iconsDone = false
        wsListProc.command = [root.homeDir + "/.local/bin/kimrity-ws", "list", "F1"]
        wsListProc.running = true
        iconsProc.command = [root.homeDir + "/.local/bin/kimrity-icons"]
        iconsProc.running = true
    }

    function wsListReady(text) {
        root.wsText = text || ""
        root.wsDone = true
        if (root.iconsDone) root.rebuildClusters()
    }

    function iconsReady(text) {
        const m = ({})
        for (const line of (text || "").split("\n")) {
            if (line.length === 0 || line.charAt(0) === "#") continue
            const i = line.indexOf("\t")
            if (i <= 0) continue
            const tool = line.slice(0, i).trim()
            let p = line.slice(i + 1).trim()
            if (tool.length === 0) continue
            if (p === "--") p = ""
            m[tool] = p
        }
        root.iconMap = m
        root.iconsDone = true
        if (root.wsDone) root.rebuildClusters()
    }

    function rebuildClusters() {
        const rows = []
        for (const line of (root.wsText || "").split("\n")) {
            const s = line.trim()
            if (s.length === 0 || s.charAt(0) === "#") continue
            const p = s.split("|")
            if (p.length < 4) continue
            let tool = (p[3] || "").trim()
            if (tool.indexOf(" ") > 0) tool = tool.split(/\s+/)[0]
            if (tool.length === 0) continue
            let ws = parseInt(p[2], 10)
            if (isNaN(ws)) ws = 1
            rows.push({
                preset: (p[0] || "").trim(),
                label: (p[1] || p[0] || "").trim(),
                ws: ws,
                tool: tool
            })
        }

        // Preset sentiasa tiga, dalam tertib ini; baris diisih ikut workspace.
        const keys = ["F1", "F2", "F3"]
        const out = []
        for (let i = 0; i < keys.length; i++) {
            const k = keys[i]
            const rs = rows.filter(r => r.preset === k)
            rs.sort((a, b) => a.ws - b.ws)
            const items = []
            for (let j = 0; j < rs.length; j++) {
                items.push({
                    tool: rs[j].tool,
                    icon: root.iconMap[rs[j].tool] || "",
                    more: false
                })
            }
            out.push({
                key: k,
                label: rs.length > 0 ? rs[0].label : k,
                count: items.length,
                tools: items
            })
        }
        root.clusters = out
    }

    // Maksimum 4 tile: 3 tool + satu tile "+N" jika lebih.
    function tilesFor(cluster) {
        const t = (cluster && cluster.tools) ? cluster.tools : []
        if (t.length <= 4) return t
        const out = t.slice(0, 3)
        out.push({ tool: "+" + (t.length - 3), icon: "", more: true })
        return out
    }

    function monogram(name) {
        return (name || "?").substring(0, 2).toUpperCase()
    }

    function hasIcon(tile) {
        return !!(tile && tile.icon && tile.icon !== "--")
    }

    function reloadRows() {
        if (root.editPreset === "") { root.editRows = []; return }
        root.wsCall(["list", root.editPreset])
    }

    function openEditor(key) {
        root.gatePage = false
        for (let i = 0; i < root.clusters.length; i++)
            if (root.clusters[i].key === key) root.wsIndex = i
        root.editPreset = key
        root.setOpen = false
        root.loadTools()
        root.reloadRows()
    }

    // ---------------- IPC ----------------
    IpcHandler {
        target: "menu"
        function toggle(): void { root.isOpen = !root.isOpen }
        function openMenu(): void { root.isOpen = true }
        function closeMenu(): void { root.isOpen = false }
        function openSettings(key: string): void { root.isOpen = true; root.openEditor(key) }
        function wsApply(key: string, baris: string, ws: string): void {
            root.isOpen = true
            if (root.editPreset !== key) root.openEditor(key)
            root.wsCall(["set", key, baris, ws])
        }
    }

    Process { id: runner; onExited: root.isOpen = false }

    function run(cmd) {
        if (!cmd) return
        // Panel (qs) tiada DISPLAY dalam env → app Java/Swing (ghidra, burp) gagal senyap.
        // _JAVA_AWT_WM_NONREPARENTING: elak tetingkap Swing putih kosong di bawah XWayland.
        runner.command = ["bash", "-lc",
            "export DISPLAY=\"${DISPLAY:-:0}\"; export _JAVA_AWT_WM_NONREPARENTING=1; " + cmd]
        runner.running = true
        root.isOpen = false
    }

    function handleFieldKey(e) {
        if (e.key === Qt.Key_Escape || e.key === Qt.Key_F1
                || e.key === Qt.Key_F2 || e.key === Qt.Key_F3)
            root.handleKey(e)
    }

    function presetKey(key) {
        // Editor terbuka: tukar preset di tempat, jangan lancar workspace.
        if (root.editPreset !== "") {
            root.openEditor(key)
            return
        }
        root.run("$HOME/.local/bin/workspace-launch " + key)
    }

    function handleKey(e) {
        switch (e.key) {
        case Qt.Key_Escape:
            root.isOpen = false; e.accepted = true; break
        case Qt.Key_F1: root.presetKey("F1"); e.accepted = true; break
        case Qt.Key_F2: root.presetKey("F2"); e.accepted = true; break
        case Qt.Key_F3: root.presetKey("F3"); e.accepted = true; break
        case Qt.Key_Down:  root.appIndex = Math.min(root.appIndex + 2, root.apps.length - 1); e.accepted = true; break
        case Qt.Key_Up:    root.appIndex = Math.max(root.appIndex - 2, 0); e.accepted = true; break
        case Qt.Key_Right: root.appIndex = Math.min(root.appIndex + 1, root.apps.length - 1); e.accepted = true; break
        case Qt.Key_Left:  root.appIndex = Math.max(root.appIndex - 1, 0); e.accepted = true; break
        case Qt.Key_Return:
        case Qt.Key_Enter:
            if (root.editPreset === "" && !root.noteEdit && root.apps[root.appIndex])
                root.run(root.apps[root.appIndex].cmd)
            e.accepted = true; break
        }
    }

    // ---------------- tetingkap ----------------
    LazyLoader {
        active: root.isOpen

    PanelWindow {
        id: panel
        anchors { left: true; top: true }
        margins { left: 10; top: 96 }
        implicitWidth: 1020
        implicitHeight: 576
        color: "transparent"
        exclusiveZone: 0
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.isOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        FocusScope {
            anchors.fill: parent
            focus: root.isOpen
            Keys.onPressed: (e) => root.handleKey(e)

            Rectangle {
                anchors.fill: parent
                color: "#0a0f1e"
                radius: 12
                border.color: "#1a2336"
                border.width: 1

                // ================= editor seting preset =================
                Rectangle {
                    id: editor
                    visible: root.editPreset !== ""
                    z: 10
                    x: 184; y: 8
                    width: parent.width - 192
                    height: parent.height - 16
                    radius: 11; color: "#101728"

                    // telan klik kosong supaya tidak tembus ke dashboard di belakang
                    MouseArea { anchors.fill: parent; onClicked: {} }

                    Column {
                        anchors.fill: parent
                        anchors.margins: 14
                        spacing: 8

                        Row {
                            width: parent.width
                            spacing: 12
                            Text {
                                text: "Seting · " + root.editPreset + " " + (root.clusters[root.wsIndex] ? root.clusters[root.wsIndex].label : "")
                                color: "#e3ebff"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 13
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Rectangle {
                                width: 150; height: 28; radius: 7
                                color: "#12343a"; border.color: "#2f6f69"; border.width: 1
                                anchors.verticalCenter: parent.verticalCenter
                                Text {
                                    anchors.centerIn: parent
                                    text: "Semua → Tab 1"; color: "#4fd1c5"
                                    font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: root.wsCall(["all", root.editPreset, "1"])
                                }
                            }
                        }

                        Text {
                            text: "Nombor = workspace. Sama nombor = tab sama. Klik untuk tukar."
                            color: "#5b6784"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9
                        }

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: 10
                            spacing: 8
                            Text {
                                text: "TAB"; width: 196; color: "#5f6c8c"
                                font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9
                            }
                            Text {
                                text: "TOOLS"; width: 118; color: "#5f6c8c"
                                font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9
                            }
                            Text {
                                text: "ARAHAN / LINK"; color: "#5f6c8c"
                                font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9
                            }
                        }

                        Repeater {
                            model: root.editRows
                            delegate: Rectangle {
                                id: rowCard
                                required property int index
                                required property var modelData
                                property var row: modelData
                                property int rowNo: index + 1
                                width: parent.width
                                height: 40
                                radius: 8
                                color: index % 2 === 0 ? "#0d1424" : "#0f1727"

                                Row {
                                    anchors.fill: parent
                                    anchors.leftMargin: 10
                                    anchors.rightMargin: 8
                                    spacing: 8

                                    Text {
                                        text: rowNo; width: 16; color: "#7a86a6"
                                        anchors.verticalCenter: parent.verticalCenter
                                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11
                                    }

                                    Repeater {
                                        model: [1, 2, 3, 4, 5]
                                        delegate: Rectangle {
                                            required property var modelData
                                            width: 28; height: 28; radius: 7
                                            color: modelData === row.ws ? "#4fd1c5" : "#182236"
                                            border.width: modelData === row.ws ? 0 : 1
                                            border.color: "#25314a"
                                            anchors.verticalCenter: parent.verticalCenter
                                            Text {
                                                anchors.centerIn: parent
                                                text: modelData
                                                color: modelData === row.ws ? "#06221f" : "#8f9cbb"
                                                font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11
                                                font.bold: modelData === row.ws
                                            }
                                            MouseArea {
                                                anchors.fill: parent
                                                onClicked: root.wsCall(["set", root.editPreset, String(rowNo), String(modelData)])
                                            }
                                        }
                                    }

                                    Rectangle {
                                        width: 110; height: 28; radius: 6
                                        color: "#0a1120"
                                        border.color: (root.tools.length > 0 && root.tools.indexOf(row.tool) < 0) ? "#7a3b46" : "#2b3a56"
                                        border.width: 1
                                        anchors.verticalCenter: parent.verticalCenter

                                        TextInput {
                                            id: toolInput
                                            anchors.fill: parent
                                            anchors.leftMargin: 8
                                            anchors.rightMargin: 6
                                            verticalAlignment: TextInput.AlignVCenter
                                            text: row.tool
                                            color: "#f1f6ff"
                                            clip: true
                                            selectByMouse: true
                                            font.family: "JetBrainsMono Nerd Font"
                                            font.pixelSize: 10
                                            font.bold: true
                                            Keys.onPressed: (e) => root.handleFieldKey(e)
                                            onAccepted: {
                                                if (text !== row.tool) root.wsCall(["settool", root.editPreset, String(rowNo), text])
                                            }
                                            onEditingFinished: {
                                                if (text !== row.tool) root.wsCall(["settool", root.editPreset, String(rowNo), text])
                                            }
                                        }
                                    }

                                    Rectangle {
                                        width: rowCard.width - 418; height: 28; radius: 6
                                        color: "#0a1120"; border.color: "#2b3a56"; border.width: 1
                                        anchors.verticalCenter: parent.verticalCenter

                                        TextInput {
                                            id: argsInput
                                            anchors.fill: parent
                                            anchors.leftMargin: 8
                                            anchors.rightMargin: 6
                                            verticalAlignment: TextInput.AlignVCenter
                                            text: row.args
                                            color: "#a9b6d4"
                                            clip: true
                                            selectByMouse: true
                                            font.family: "JetBrainsMono Nerd Font"
                                            font.pixelSize: 10
                                            Keys.onPressed: (e) => root.handleFieldKey(e)
                                            onAccepted: {
                                                if (text !== row.args) root.wsCall(["setargs", root.editPreset, String(rowNo), text])
                                            }
                                            onEditingFinished: {
                                                if (text !== row.args) root.wsCall(["setargs", root.editPreset, String(rowNo), text])
                                            }
                                        }
                                    }

                                    Rectangle {
                                        width: 62; height: 26; radius: 6
                                        color: "#2a1620"; border.color: "#5c2b33"; border.width: 1
                                        anchors.verticalCenter: parent.verticalCenter
                                        Text {
                                            anchors.centerIn: parent
                                            text: "Buang"; color: "#e08b95"
                                            font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            onClicked: root.wsCall(["del", root.editPreset, String(rowNo)])
                                        }
                                    }
                                }
                            }
                        }

                        Rectangle {
                            id: addBlock
                            width: parent.width
                            height: 56
                            radius: 9
                            color: "#0d1424"
                            border.color: "#2b3a56"
                            border.width: 1

                            Row {
                                anchors.fill: parent
                                anchors.margins: 11
                                spacing: 8

                                Rectangle {
                                    id: addToolBox
                                    width: 130
                                    height: 34
                                    radius: 7
                                    color: "#0a1120"
                                    border.color: addTool.activeFocus ? "#3c6f8f" : "#33445f"
                                    border.width: 1
                                    anchors.verticalCenter: parent.verticalCenter

                                    TextInput {
                                        id: addTool
                                        anchors.fill: parent
                                        anchors.leftMargin: 10
                                        anchors.rightMargin: 8
                                        verticalAlignment: TextInput.AlignVCenter
                                        color: "#f1f6ff"
                                        clip: true
                                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11
                                        font.bold: true
                                        onTextChanged: root.updateHits(text)
                                        Keys.onPressed: (e) => {
                                            if (e.key === Qt.Key_Down && root.toolHits.length > 0) {
                                                addTool.text = root.toolHits[0]
                                                root.toolHits = []
                                                e.accepted = true
                                            } else root.handleFieldKey(e)
                                        }
                                        Text {
                                            visible: parent.text.length === 0
                                            text: "tool — cth: firefox"
                                            color: "#6c7a9c"; font: parent.font
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }
                                }

                                Rectangle {
                                    width: parent.width - 422
                                    height: 34
                                    radius: 7
                                    color: "#0a1120"
                                    border.color: "#33445f"
                                    border.width: 1
                                    anchors.verticalCenter: parent.verticalCenter

                                    TextInput {
                                        id: addArgs
                                        anchors.fill: parent
                                        anchors.leftMargin: 10
                                        anchors.rightMargin: 8
                                        verticalAlignment: TextInput.AlignVCenter
                                        color: "#eef3ff"
                                        clip: true
                                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11
                                        Keys.onPressed: (e) => root.handleFieldKey(e)
                                        Text {
                                            visible: parent.text.length === 0
                                            text: "arahan / link — cth: https://youtube.com"
                                            color: "#6c7a9c"; font: parent.font
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }
                                }

                                Repeater {
                                    model: [1, 2, 3, 4, 5]
                                    delegate: Rectangle {
                                        required property var modelData
                                        width: 28; height: 28; radius: 7
                                        color: root.newWs === modelData ? "#4fd1c5" : "#182236"
                                        border.width: root.newWs === modelData ? 0 : 1
                                        border.color: "#25314a"
                                        anchors.verticalCenter: parent.verticalCenter
                                        Text {
                                            anchors.centerIn: parent
                                            text: modelData
                                            color: root.newWs === modelData ? "#06221f" : "#8f9cbb"
                                            font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11
                                            font.bold: root.newWs === modelData
                                        }
                                        MouseArea { anchors.fill: parent; onClicked: root.newWs = modelData }
                                    }
                                }

                                Rectangle {
                                    width: 96; height: 34; radius: 7
                                    color: "#2fbfae"
                                    anchors.verticalCenter: parent.verticalCenter

                                    Text {
                                        anchors.centerIn: parent
                                        text: "＋ Tambah"; color: "#06221f"
                                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11
                                        font.bold: true
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: {
                                            let t = addTool.text.trim()
                                            let a = addArgs.text.trim()
                                            // pisahkan jika link tersalah taip dalam kotak tool
                                            const i = t.indexOf("http")
                                            if (i > 0) {
                                                a = t.slice(i) + (a.length > 0 ? " " + a : "")
                                                t = t.slice(0, i)
                                            } else if (i === 0) {
                                                a = t
                                                t = "firefox"
                                            }
                                            if (t.length > 0) {
                                                root.wsCall(["add", root.editPreset, String(root.newWs), t, a])
                                                addTool.text = ""
                                                addArgs.text = ""
                                                root.toolHits = []
                                            }
                                        }
                                    }
                                }
                            }

                            // dropdown tool yang memang terpasang
                            Rectangle {
                                id: toolDrop
                                visible: addTool.activeFocus && root.toolHits.length > 0
                                z: 40
                                x: addToolBox.mapToItem(addBlock, 0, 0).x
                                y: addBlock.height + 4
                                width: Math.max(addToolBox.width, 150)
                                height: Math.min(root.toolHits.length, 8) * 21 + 8
                                radius: 7
                                color: "#0b1222"
                                border.color: "#33445f"
                                border.width: 1

                                Column {
                                    anchors.fill: parent
                                    anchors.margins: 4
                                    spacing: 1
                                    Repeater {
                                        model: root.toolHits
                                        delegate: Rectangle {
                                            id: hitRow
                                            required property var modelData
                                            width: parent.width
                                            height: 21
                                            radius: 4
                                            color: hitMouse.containsMouse ? "#16304a" : "transparent"
                                            Text {
                                                anchors.left: parent.left
                                                anchors.leftMargin: 8
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: modelData
                                                color: "#dbe6ff"
                                                font.family: "JetBrainsMono Nerd Font"
                                                font.pixelSize: 10
                                            }
                                            MouseArea {
                                                id: hitMouse
                                                anchors.fill: parent
                                                hoverEnabled: true
                                onClicked: {
                                                    addTool.text = modelData
                                                    root.toolHits = []
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // ================= halaman Gate =================
                Rectangle {
                    id: gatePageBox
                    visible: root.gatePage
                    z: 9
                    x: 184; y: 8
                    width: parent.width - 192
                    height: parent.height - 16
                    radius: 11
                    color: "#0a0f1e"

                    readonly property int scannerH: (root.gateRunning || root.gateScanners.length > 0) ? 74 : 0

                    // telan klik kosong supaya tidak tembus ke dashboard di belakang
                    MouseArea { anchors.fill: parent; onClicked: {} }

                    Column {
                        anchors.fill: parent
                        anchors.margins: 14
                        spacing: 10

                        Item {
                            width: parent.width; height: 22
                            Text {
                                id: gateTitle
                                text: "Gate"; color: "#e3ebff"
                                font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 15
                                font.bold: true
                            }
                            Text {
                                anchors.left: gateTitle.right; anchors.leftMargin: 10
                                anchors.verticalCenter: gateTitle.verticalCenter
                                text: "Security Gate · pilih sasaran, jalankan scanner, baca keputusan CLI"
                                color: "#5b6784"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9
                            }
                            Text {
                                anchors.right: parent.right; anchors.verticalCenter: gateTitle.verticalCenter
                                text: root.gateLoadedJson.length > 0 ? "gate.json" : "belum ada imbasan"
                                color: "#4f5d7b"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9
                            }
                        }

                        // ----- sasaran + jenis + kebenaran + run -----
                        Item {
                            width: parent.width; height: 34

                            Rectangle {
                                id: gateTargetBox
                                x: 0; anchors.verticalCenter: parent.verticalCenter
                                width: 328; height: 34; radius: 7
                                color: "#0d1424"
                                border.width: 1
                                border.color: gateTargetInput.activeFocus ? "#2f6f69" : "#1c2740"

                                Text {
                                    visible: gateTargetInput.text.length === 0
                                    x: 10; anchors.verticalCenter: parent.verticalCenter
                                    text: "Sasaran — folder/repo, URL, atau host"
                                    color: "#5b6784"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10
                                }
                                TextInput {
                                    id: gateTargetInput
                                    anchors.fill: parent
                                    anchors.leftMargin: 10; anchors.rightMargin: 8
                                    verticalAlignment: TextInput.AlignVCenter
                                    text: root.gateTarget
                                    color: "#eef3ff"
                                    clip: true
                                    selectByMouse: true
                                    font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11
                                    onTextChanged: root.gateTarget = text
                                    Keys.onPressed: (e) => {
                                        if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                                            root.startGate()
                                            e.accepted = true
                                        } else {
                                            root.handleFieldKey(e)
                                        }
                                    }
                                }
                            }

                            Row {
                                id: gateKindRow
                                x: gateTargetBox.width + 8
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 4
                                Repeater {
                                    model: [
                                        { k: "repo", l: "Folder/Repo" },
                                        { k: "web", l: "Web" },
                                        { k: "server", l: "Server" }
                                    ]
                                    delegate: Rectangle {
                                        required property var modelData
                                        width: modelData.k === "repo" ? 82 : (modelData.k === "web" ? 44 : 52)
                                        height: 28; radius: 14
                                        color: root.gateKind === modelData.k ? "#12343a" : "#101728"
                                        border.width: 1
                                        border.color: root.gateKind === modelData.k ? "#2f6f69" : "#243149"
                                        opacity: root.gateRunning ? 0.55 : 1
                                        Text {
                                            anchors.centerIn: parent
                                            text: modelData.l
                                            color: root.gateKind === modelData.k ? "#4fd1c5" : "#93a1c0"
                                            font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            onClicked: if (!root.gateRunning) root.gateKind = modelData.k
                                        }
                                    }
                                }
                            }

                            Rectangle {
                                id: gateAuthBox
                                x: gateKindRow.x + gateKindRow.width + 14
                                anchors.verticalCenter: parent.verticalCenter
                                width: 156; height: 28
                                color: "transparent"
                                Row {
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 6
                                    Rectangle {
                                        width: 14; height: 14; radius: 3
                                        color: "transparent"; border.width: 1
                                        border.color: root.gateAuthorized ? "#4fd1c5" : "#4a5774"
                                        Text {
                                            anchors.centerIn: parent
                                            visible: root.gateAuthorized
                                            text: "✓"; color: "#4fd1c5"
                                            font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9
                                        }
                                    }
                                    Text {
                                        text: "Saya ada kebenaran"
                                        color: (root.gateKind === "repo")
                                            ? "#5b6784"
                                            : (root.gateAuthorized ? "#c9d4ec" : "#c08a62")
                                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: if (!root.gateRunning) root.gateAuthorized = !root.gateAuthorized
                                }
                            }

                            Rectangle {
                                id: gateRunBtn
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                width: 92; height: 34; radius: 8
                                color: root.gateRunning ? "#182236" : (root.gateCanRun ? "#12343a" : "#121a2b")
                                border.width: 1
                                border.color: root.gateCanRun ? "#2f6f69" : "#243149"
                                opacity: root.gateCanRun ? 1 : 0.55
                                Text {
                                    anchors.centerIn: parent
                                    text: root.gateRunning ? "Mengimbas…" : "Run"
                                    color: root.gateRunning ? "#e0a34a" : (root.gateCanRun ? "#4fd1c5" : "#5b6784")
                                    font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10
                                    font.bold: true
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: root.startGate()
                                }
                            }
                        }

                        // ----- keputusan + scanner + dapatan | sejarah + AI -----
                        Row {
                            width: parent.width
                            height: parent.height - 22 - 34 - 20
                            spacing: 10

                            Column {
                                width: parent.width - 246
                                height: parent.height
                                spacing: 8

                                // verdict + kiraan
                                Rectangle {
                                    width: parent.width; height: 66
                                    radius: 10; color: "#101728"

                                    Rectangle {
                                        x: 12; y: 13
                                        width: 160; height: 40; radius: 8
                                        color: "#0d1424"
                                        border.width: 1
                                        border.color: root.gateRunning ? "#e0a34a"
                                            : (root.gateError !== "" ? "#e8443a"
                                            : (root.gateVerdict !== "" ? root.gateVerdictColor(root.gateVerdict) : "#243149"))
                                        Text {
                                            anchors.centerIn: parent
                                            text: root.gateRunning ? "MENGIMBAS…"
                                                : (root.gateError !== "" ? "RALAT"
                                                : (root.gateVerdict !== "" ? root.gateVerdictLabel(root.gateVerdict) : "—"))
                                            color: root.gateRunning ? "#e0a34a"
                                                : (root.gateError !== "" ? "#e8443a"
                                                : (root.gateVerdict !== "" ? root.gateVerdictColor(root.gateVerdict) : "#5b6784"))
                                            font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 14
                                            font.bold: true
                                        }
                                    }

                                    Row {
                                        x: 184; y: 12
                                        spacing: 18
                                        Repeater {
                                            model: [
                                                { key: "high", label: "HIGH" },
                                                { key: "medium", label: "MED" },
                                                { key: "low", label: "LOW" }
                                            ]
                                            delegate: Column {
                                                required property var modelData
                                                spacing: 2
                                                Text {
                                                    text: modelData.label
                                                    color: "#5f6c8c"
                                                    font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 8
                                                }
                                                Text {
                                                    text: root.gateCount(modelData.key)
                                                    color: root.gateSevColor(modelData.key)
                                                    font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 14
                                                    font.bold: true
                                                }
                                            }
                                        }
                                    }

                                    Text {
                                        x: 184; y: 42
                                        width: parent.width - 196
                                        text: root.gateError !== "" ? root.gateError
                                            : (root.gateReason !== "" ? root.gateReason
                                            : (root.gateRunning ? "Scanner sedang berjalan…" : "Belum ada imbasan."))
                                        color: root.gateError !== "" ? "#e08b95" : "#7d8aa8"
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
                                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9
                                    }
                                }

                                // status scanner (NDJSON)
                                Rectangle {
                                    visible: gatePageBox.scannerH > 0
                                    width: parent.width; height: gatePageBox.scannerH
                                    radius: 10; color: "#101728"

                                    Text {
                                        x: 12; y: 8; text: "Scanner"; color: "#b9c6e2"
                                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10
                                    }
                                    Text {
                                        anchors.right: parent.right; anchors.rightMargin: 12; y: 9
                                        text: root.gateRunning ? "NDJSON · live" : "NDJSON"
                                        color: "#4f5d7b"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 8
                                    }

                                    ListView {
                                        anchors.left: parent.left; anchors.right: parent.right
                                        anchors.top: parent.top; anchors.topMargin: 26
                                        anchors.bottom: parent.bottom; anchors.bottomMargin: 8
                                        anchors.leftMargin: 12; anchors.rightMargin: 8
                                        clip: true
                                        spacing: 2
                                        model: root.gateScanners
                                        delegate: Rectangle {
                                            required property var modelData
                                            width: ListView.view.width
                                            height: 18
                                            color: "transparent"
                                            Row {
                                                anchors.fill: parent
                                                spacing: 6
                                                Rectangle {
                                                    width: 6; height: 6; radius: 3
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    color: modelData.status === "done" ? "#3fbf8f"
                                                        : (modelData.status === "failed" ? "#e8443a" : "#e0a34a")
                                                }
                                                Text {
                                                    width: 78
                                                    text: modelData.name
                                                    color: "#c9d4ec"
                                                    elide: Text.ElideRight
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9
                                                }
                                                Text {
                                                    width: 48
                                                    text: modelData.status
                                                    color: modelData.status === "done" ? "#3fbf8f"
                                                        : (modelData.status === "failed" ? "#e8443a" : "#e0a34a")
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9
                                                }
                                                Text {
                                                    width: parent.width - 6 - 78 - 48 - 18
                                                    text: modelData.reason
                                                    color: "#7d8aa8"
                                                    elide: Text.ElideRight
                                                    maximumLineCount: 1
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9
                                                }
                                            }
                                        }
                                        ScrollBar.vertical: ScrollBar { width: 4; policy: ScrollBar.AsNeeded }
                                    }

                                    Text {
                                        visible: root.gateScanners.length === 0
                                        x: 12; y: 34
                                        text: root.gateRunning ? "Menyediakan…" : "Tiada status scanner."
                                        color: "#5b6784"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9
                                    }
                                }

                                // jadual dapatan
                                Rectangle {
                                    width: parent.width
                                    height: parent.height - 66 - 8 - (gatePageBox.scannerH > 0 ? gatePageBox.scannerH + 8 : 0)
                                    radius: 10; color: "#101728"

                                    Text {
                                        x: 12; y: 9; text: "Dapatan"; color: "#b9c6e2"
                                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10
                                    }
                                    Text {
                                        anchors.right: parent.right; anchors.rightMargin: 12; y: 10
                                        text: root.gateFindings.length + " isu"
                                        color: "#4f5d7b"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 8
                                    }

                                    Column {
                                        id: gateFindingsCol
                                        anchors.left: parent.left; anchors.right: parent.right
                                        anchors.top: parent.top; anchors.topMargin: 28
                                        anchors.leftMargin: 12; anchors.rightMargin: 12
                                        spacing: 1

                                        Row {
                                            width: parent.width; height: 16
                                            spacing: 4
                                            Text {
                                                width: 54; text: "TAHAP"; color: "#5f6c8c"
                                                font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 8
                                            }
                                            Text {
                                                width: 64; text: "ALAT"; color: "#5f6c8c"
                                                font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 8
                                            }
                                            Text {
                                                width: parent.width - 54 - 64 - 110 - 12
                                                text: "ISU"; color: "#5f6c8c"
                                                font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 8
                                            }
                                            Text {
                                                width: 110; text: "LOKASI"; color: "#5f6c8c"
                                                font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 8
                                            }
                                        }

                                        Text {
                                            visible: root.gateFindings.length === 0
                                            text: root.gateRunning ? "Menunggu keputusan…"
                                                : (root.gateDone ? "Tiada dapatan dilaporkan." : "Belum ada imbasan.")
                                            color: "#5b6784"
                                            font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9
                                        }

                                        Repeater {
                                            model: root.gateFindings.slice(0, 12)
                                            delegate: Rectangle {
                                                required property var modelData
                                                width: gateFindingsCol.width
                                                height: 18
                                                color: "transparent"
                                                Row {
                                                    anchors.fill: parent
                                                    spacing: 4
                                                    Text {
                                                        width: 54
                                                        text: String(modelData.severity || "")
                                                        color: root.gateSevColor(modelData.severity)
                                                        elide: Text.ElideRight
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9
                                                    }
                                                    Text {
                                                        width: 64
                                                        text: String(modelData.tool || "")
                                                        color: "#93a1c0"
                                                        elide: Text.ElideRight
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9
                                                    }
                                                    Text {
                                                        width: parent.width - 54 - 64 - 110 - 12
                                                        text: String(modelData.message || "")
                                                        color: "#c9d4ec"
                                                        elide: Text.ElideRight
                                                        maximumLineCount: 1
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9
                                                    }
                                                    Text {
                                                        width: 110
                                                        text: root.gateLocation(modelData)
                                                        color: "#5b6784"
                                                        elide: Text.ElideMiddle
                                                        maximumLineCount: 1
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 8
                                                    }
                                                }
                                            }
                                        }

                                        Text {
                                            visible: root.gateFindings.length > 12
                                            text: "+" + (root.gateFindings.length - 12) + " lagi"
                                            color: "#4fd1c5"
                                            font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 8
                                        }
                                    }
                                }
                            }

                            Column {
                                width: 236
                                height: parent.height
                                spacing: 8

                                // sejarah 5 imbasan terakhir
                                Rectangle {
                                    width: parent.width; height: 210
                                    radius: 10; color: "#101728"

                                    Text {
                                        x: 12; y: 9; text: "Sejarah"; color: "#b9c6e2"
                                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10
                                    }
                                    Text {
                                        anchors.right: parent.right; anchors.rightMargin: 12; y: 10
                                        text: "5 terkini"
                                        color: "#4f5d7b"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 8
                                    }

                                    Column {
                                        anchors.left: parent.left; anchors.right: parent.right
                                        anchors.top: parent.top; anchors.topMargin: 30
                                        anchors.leftMargin: 12; anchors.rightMargin: 12
                                        spacing: 2

                                        Text {
                                            visible: root.gateHistory.length === 0
                                            text: root.gateHistoryLoading ? "Memuatkan…" : "Tiada imbasan lagi."
                                            color: "#5b6784"
                                            font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9
                                        }

                                        Repeater {
                                            model: root.gateHistory
                                            delegate: Rectangle {
                                                required property var modelData
                                                width: parent.width; height: 30; radius: 6
                                                color: histMouse.containsMouse ? "#182236" : "transparent"
                                                opacity: root.gateRunning ? 0.5 : 1
                                                Text {
                                                    anchors.left: parent.left; anchors.leftMargin: 7
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    width: parent.width - 14
                                                    text: modelData
                                                    color: "#c9d4ec"
                                                    elide: Text.ElideMiddle
                                                    maximumLineCount: 1
                                                    font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9
                                                }
                                                MouseArea {
                                                    id: histMouse
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    enabled: !root.gateRunning
                                                    onClicked: root.loadGateHistory(modelData)
                                                }
                                            }
                                        }
                                    }
                                }

                                // placeholder AI — sengaja tiada logik
                                Rectangle {
                                    width: parent.width
                                    height: parent.height - 210 - 8
                                    radius: 10
                                    color: "#0d1424"
                                    border.width: 1
                                    border.color: "#243149"

                                    Text {
                                        x: 12; y: 10
                                        text: "Analisis AI — belum tersedia"
                                        color: "#5b6784"
                                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10
                                    }
                                    Text {
                                        x: 12; y: 32
                                        width: parent.width - 24
                                        text: "Versi Gate ini hanya memaparkan keputusan peraturan CLI. Tiada model AI digunakan."
                                        color: "#46536f"
                                        wrapMode: Text.WordWrap
                                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9
                                    }
                                }
                            }
                        }
                    }
                }

                Row {
                    anchors.fill: parent
                    anchors.margins: 8
                    spacing: 8

                    // ================= sidebar =================
                    Rectangle {
                        width: 168; height: parent.height
                        radius: 11; color: "#101728"

                        Column {
                            anchors.fill: parent
                            anchors.margins: 10
                            spacing: 2

                            Rectangle {
                                width: parent.width; height: 30; radius: 7; color: "#0d1424"
                                Row {
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.left: parent.left; anchors.leftMargin: 9
                                    spacing: 7
                                    Text { text: "\uf002"; color: "#5b6784"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11 }
                                    TextInput {
                                        id: search
                                        width: 118
                                        color: "#dbe3f4"
                                        font.family: "JetBrainsMono Nerd Font"
                                        font.pixelSize: 11
                                        focus: root.isOpen
                                        onTextChanged: { root.filter = text; root.appIndex = 0 }
                                        Keys.onPressed: (e) => root.handleKey(e)
                                        Text { visible: parent.text.length === 0; text: "Search…"; color: "#5b6784"; font: parent.font }
                                    }
                                }
                            }

                            Item { width: 1; height: 4 }

                            Rectangle {
                                width: parent.width; height: 28; radius: 6
                                color: (root.catIndex === -1 && root.editPreset === "" && !root.gatePage) ? "#182236" : "transparent"
                                Rectangle {
                                    width: 2; height: parent.height - 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: "#4fd1c5"; visible: root.catIndex === -1 && root.editPreset === "" && !root.gatePage
                                }
                                Row {
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.left: parent.left; anchors.leftMargin: 9
                                    spacing: 8
                                    Text { text: "\uf00a"; color: (root.catIndex === -1 && root.editPreset === "" && !root.gatePage) ? "#4fd1c5" : "#66738f"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11 }
                                    Text { text: "Quick access"; color: (root.catIndex === -1 && root.editPreset === "" && !root.gatePage) ? "#e7eeff" : "#93a1c0"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11 }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: {
                                        root.gatePage = false
                                        root.editPreset = ""
                                        root.noteEdit = false
                                        root.notesMenuOpen = false
                                        root.catIndex = -1
                                        root.appIndex = 0
                                    }
                                }
                            }

                            // --- dropdown: Seting preset ---
                            Rectangle {
                                width: parent.width; height: 26; radius: 6; color: "transparent"
                                Row {
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.left: parent.left; anchors.leftMargin: 9
                                    spacing: 8
                                    Text { text: "\uf013"; color: "#66738f"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11 }
                                    Text { text: "Seting preset"; color: "#93a1c0"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11 }
                                    Text {
                                        text: root.setOpen ? "\uf077" : "\uf078"
                                        color: "#66738f"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9
                                    }
                                }
                                MouseArea { anchors.fill: parent; onClicked: root.setOpen = !root.setOpen }
                            }

                            Column {
                                visible: root.setOpen
                                width: parent.width
                                spacing: 1
                                Repeater {
                                    model: root.clusters
                                    delegate: Rectangle {
                                        required property var modelData
                                        width: parent.width; height: 24; radius: 6
                                        color: root.editPreset === modelData.key ? "#182236" : "transparent"
                                        Row {
                                            anchors.verticalCenter: parent.verticalCenter
                                            anchors.left: parent.left; anchors.leftMargin: 26
                                            spacing: 7
                                            Text { text: modelData.key; color: "#4fd1c5"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10 }
                                            Text { text: modelData.label; color: "#93a1c0"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10 }
                                        }
                                        MouseArea { anchors.fill: parent; onClicked: root.openEditor(modelData.key) }
                                    }
                                }
                            }

                            // tolak baki ke bawah
                            Item { width: 1; height: Math.max(0, parent.height - 30 - 4 - 28 - 26 - 26 - 26 - 4 - (root.setOpen ? 100 : 0)) }

                            Rectangle {
                                width: parent.width; height: 26; radius: 6; color: "transparent"
                                Row {
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.left: parent.left; anchors.leftMargin: 9
                                    spacing: 8
                                    Text { text: "\uf013"; color: "#66738f"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11 }
                                    Text { text: "Settings"; color: "#93a1c0"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11 }
                                }
                                MouseArea { anchors.fill: parent; onClicked: root.run("kitty -e nvim ~/.config/hypr/hyprland.conf") }
                            }

                            Rectangle {
                                width: parent.width; height: 26; radius: 6
                                color: root.gatePage ? "#182236" : "transparent"
                                Rectangle {
                                    width: 2; height: parent.height - 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: "#4fd1c5"; visible: root.gatePage
                                }
                                Row {
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.left: parent.left; anchors.leftMargin: 9
                                    spacing: 8
                                    Text { text: "\uf132"; color: root.gatePage ? "#4fd1c5" : "#66738f"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11 }
                                    Text { text: "Gate"; color: root.gatePage ? "#e7eeff" : "#93a1c0"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11 }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: {
                                        root.editPreset = ""
                                        root.noteEdit = false
                                        root.notesMenuOpen = false
                                        root.gatePage = true
                                        root.refreshGateHistory()
                                    }
                                }
                            }
                        }
                    }

                    // ================= lajur utama =================
                    Column {
                        width: parent.width - 176
                        height: parent.height
                        spacing: 8

                        // ----- workspace -----
                        Rectangle {
                            width: parent.width; height: 168
                            radius: 11; color: "#101728"

                            Text {
                                x: 12; y: 10; text: "Workspace"; color: "#b9c6e2"
                                font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11
                            }
                            Text {
                                anchors.right: parent.right; anchors.rightMargin: 12; y: 11
                                text: "F1–F3: lancar semua app ke workspace 1–3"
                                color: "#5b6784"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10
                            }

                            Row {
                                anchors.left: parent.left; anchors.leftMargin: 14
                                anchors.top: parent.top; anchors.topMargin: 30
                                spacing: 16

                                Repeater {
                                    model: root.clusters
                                    delegate: Column {
                                        required property int index
                                        required property var modelData
                                        property var cluster: modelData
                                        width: 100; spacing: 3

                                        Item {
                                            width: 96; height: 96
                                            anchors.horizontalCenter: parent.horizontalCenter

                                            Rectangle {
                                                anchors.centerIn: parent
                                                width: 96; height: 96; radius: 48
                                                color: "#e9ecf5"
                                                border.width: root.wsIndex === index ? 2 : 0
                                                border.color: "#4fd1c5"
                                                scale: root.wsIndex === index ? 1.06 : 1.0

                                                // Satu baris -> satu tile besar; jika tidak 2x2.
                                                Item {
                                                    anchors.centerIn: parent
                                                    width: cluster.count === 1 ? 64 : 70
                                                    height: cluster.count === 1 ? 74 : 70

                                                    Grid {
                                                        anchors.centerIn: parent
                                                        columns: cluster.count === 1 ? 1 : 2
                                                        columnSpacing: cluster.count === 1 ? 0 : 2
                                                        rowSpacing: cluster.count === 1 ? 0 : 2

                                                        Repeater {
                                                            model: root.tilesFor(cluster)
                                                            delegate: Column {
                                                                required property var modelData
                                                                width: cluster.count === 1 ? 64 : 34
                                                                spacing: 0

                                                                Rectangle {
                                                                    anchors.horizontalCenter: parent.horizontalCenter
                                                                    width: cluster.count === 1 ? 56 : 34
                                                                    height: width
                                                                    radius: cluster.count === 1 ? 12 : 8
                                                                    color: modelData.more ? "#d7deea"
                                                                         : (root.hasIcon(modelData) ? "#ffffff" : "#64748f")
                                                                    border.width: 1
                                                                    border.color: modelData.more ? "#b9c4d6"
                                                                                : (root.hasIcon(modelData) ? "#c7d1e2" : "#4d5c78")

                                                                    Image {
                                                                        anchors.horizontalCenter: parent.horizontalCenter
                                                                        y: cluster.count === 1 ? (parent.height - height) / 2 : 1
                                                                        visible: root.hasIcon(modelData)
                                                                        width: cluster.count === 1 ? 48 : 22
                                                                        height: width
                                                                        source: root.hasIcon(modelData) ? "file://" + modelData.icon : ""
                                                                        sourceSize.width: cluster.count === 1 ? 48 : 22
                                                                        fillMode: Image.PreserveAspectFit
                                                                        smooth: true
                                                                        asynchronous: true
                                                                    }

                                                                    // Fallback monogram — hanya bila tiada ikon.
                                                                    Text {
                                                                        visible: !root.hasIcon(modelData)
                                                                        text: modelData.more ? modelData.tool : root.monogram(modelData.tool)
                                                                        color: modelData.more ? "#48566f" : "#ffffff"
                                                                        width: parent.width
                                                                        height: cluster.count === 1 ? parent.height : 22
                                                                        horizontalAlignment: Text.AlignHCenter
                                                                        verticalAlignment: Text.AlignVCenter
                                                                        font.family: "JetBrainsMono Nerd Font"
                                                                        font.pixelSize: modelData.more ? 11 : (cluster.count === 1 ? 16 : 10)
                                                                        font.bold: true
                                                                    }

                                                                    // Nama tool di dalam tile (2x2): ruang 96px
                                                                    // tidak cukup untuk tile 34px + kapsyen luar.
                                                                    Text {
                                                                        visible: cluster.count > 1 && !modelData.more
                                                                        anchors.horizontalCenter: parent.horizontalCenter
                                                                        anchors.bottom: parent.bottom
                                                                        anchors.bottomMargin: 2
                                                                        width: parent.width
                                                                        horizontalAlignment: Text.AlignHCenter
                                                                        text: modelData.tool
                                                                        color: root.hasIcon(modelData) ? "#5b6784" : "#eef3ff"
                                                                        elide: Text.ElideRight
                                                                        maximumLineCount: 1
                                                                        font.family: "JetBrainsMono Nerd Font"
                                                                        font.pixelSize: 8
                                                                    }
                                                                }

                                                                // Satu baris: nama di bawah tile besar.
                                                                Text {
                                                                    visible: cluster.count === 1
                                                                    width: parent.width
                                                                    horizontalAlignment: Text.AlignHCenter
                                                                    text: modelData.tool
                                                                    color: "#5b6784"
                                                                    elide: Text.ElideRight
                                                                    maximumLineCount: 1
                                                                    font.family: "JetBrainsMono Nerd Font"
                                                                    font.pixelSize: 9
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }

                                            Rectangle {
                                                width: 20; height: 20; radius: 10
                                                color: "#e8443a"; border.width: 2; border.color: "#0a0f1e"
                                                anchors.right: parent.right; anchors.top: parent.top
                                                anchors.rightMargin: -2; anchors.topMargin: -2
                                                Text {
                                                    anchors.centerIn: parent
                                                    text: cluster.count
                                                    color: "white"
                                                    font.family: "JetBrainsMono Nerd Font"
                                                    font.pixelSize: 10; font.bold: true
                                                }
                                            }

                                            MouseArea {
                                                anchors.fill: parent
                                                onClicked: {
                                                    root.wsIndex = index
                                                    root.run("$HOME/.local/bin/workspace-launch " + cluster.key)
                                                }
                                            }
                                        }

                                        Text {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: cluster.label; color: "#c9d4ec"
                                            font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10
                                        }
                                        Text {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: cluster.key; color: "#4fd1c5"
                                            font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10
                                        }
                                    }
                                }
                            }
                        }

                        // ----- apps 2 lajur -----
                        Rectangle {
                            width: parent.width; height: 232
                            radius: 11; color: "#101728"

                            Text { x: 12; y: 10; text: "Apps"; color: "#b9c6e2"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11 }
                            Text {
                                anchors.right: parent.right; anchors.rightMargin: 12; y: 11
                                text: root.apps.length + " app · 2 lajur"
                                color: "#5b6784"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10
                            }

                            Grid {
                                id: appGrid
                                anchors.left: parent.left; anchors.right: parent.right
                                anchors.top: parent.top; anchors.topMargin: 32
                                anchors.margins: 12
                                anchors.rightMargin: 12
                                columns: 2
                                columnSpacing: 0
                                rowSpacing: 0

                                Repeater {
                                    model: root.apps
                                    delegate: Rectangle {
                                        required property int index
                                        required property var modelData
                                        width: appGrid.width / 2
                                        height: 28; radius: 6
                                        color: root.appIndex === index ? "#182236" : "transparent"

                                        Column {
                                            anchors.centerIn: parent
                                            spacing: 0

                                            Image {
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                visible: modelData.icon.length > 0
                                                width: 18; height: 18
                                                source: modelData.icon.length > 0 ? "file://" + modelData.icon : ""
                                                sourceSize.width: 22
                                                fillMode: Image.PreserveAspectFit
                                                smooth: true
                                                asynchronous: true
                                            }

                                            // Fallback monogram apabila iconpath ialah "--".
                                            Rectangle {
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                visible: modelData.icon.length === 0
                                                width: 18; height: 18; radius: 4; color: "#64748f"
                                                Text {
                                                    anchors.centerIn: parent
                                                    text: root.monogram(modelData.name)
                                                    color: "#ffffff"
                                                    font.family: "JetBrainsMono Nerd Font"
                                                    font.pixelSize: 8; font.bold: true
                                                }
                                            }

                                            Text {
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                width: appGrid.width / 2 - 8
                                                horizontalAlignment: Text.AlignHCenter
                                                text: modelData.name; color: "#c3cde6"
                                                elide: Text.ElideRight
                                                maximumLineCount: 1
                                                font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 8
                                            }
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            onEntered: root.appIndex = index
                                            onClicked: root.run(modelData.cmd)
                                        }
                                    }
                                }
                            }
                        }

                        // ----- recent + notes -----
                        Row {
                            width: parent.width
                            height: parent.height - 168 - 232 - 16
                            spacing: 8

                            Rectangle {
                                width: (parent.width - 8) / 2; height: parent.height
                                radius: 11; color: "#101728"

                                Text { x: 12; y: 10; text: "Recent Files"; color: "#b9c6e2"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11 }

                                Column {
                                    anchors.left: parent.left
                                    anchors.top: parent.top; anchors.topMargin: 32
                                    anchors.leftMargin: 12
                                    spacing: 2
                                    Repeater {
                                        model: root.recent
                                        delegate: Column {
                                            required property var modelData
                                            spacing: 1
                                            Text { text: modelData.n; color: "#c9d4ec"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10 }
                                            Text { text: modelData.p; color: "#5b6784"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9 }
                                        }
                                    }
                                }
                            }

                            Rectangle {
                                width: (parent.width - 8) / 2; height: parent.height
                                radius: 11; color: "#101728"

                                Text { x: 12; y: 10; text: "Notes"; color: "#b9c6e2"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11 }

                                // dropdown kecil: + Nota, + Checklist, Edit, Buang
                                Rectangle {
                                    id: notesBtn
                                    anchors.right: parent.right; anchors.rightMargin: 12; y: 9
                                    width: 26; height: 16; radius: 8
                                    color: root.notesMenuOpen ? "#182236" : "transparent"
                                    border.width: 1; border.color: "#2f6f69"
                                    Text {
                                        anchors.centerIn: parent
                                        text: "⋯"; color: "#4fd1c5"
                                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: root.notesMenuOpen = !root.notesMenuOpen
                                    }
                                }

                                Rectangle {
                                    id: notesMenu
                                    visible: root.notesMenuOpen
                                    z: 50
                                    x: notesBtn.x + notesBtn.width - width
                                    y: notesBtn.y + notesBtn.height + 4
                                    width: 124
                                    height: notesMenuCol.height + 8
                                    radius: 7; color: "#0b1222"
                                    border.color: "#33445f"; border.width: 1

                                    Column {
                                        id: notesMenuCol
                                        anchors.fill: parent
                                        anchors.margins: 4
                                        spacing: 1
                                        Repeater {
                                            model: [
                                                { label: "+ Nota", act: "note" },
                                                { label: "+ Checklist", act: "check" },
                                                { label: "Edit", act: "edit" },
                                                { label: "Buang", act: "del" }
                                            ]
                                            delegate: Rectangle {
                                                id: menuItem
                                                required property var modelData
                                                width: parent.width; height: 22; radius: 4
                                                color: menuMouse.containsMouse ? "#16304a" : "transparent"
                                                opacity: (modelData.act === "edit" || modelData.act === "del") && root.noteIndex < 0 ? 0.4 : 1
                                                Text {
                                                    anchors.left: parent.left; anchors.leftMargin: 8
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    text: modelData.label
                                                    color: modelData.act === "del" ? "#e08b95" : "#dbe6ff"
                                                    font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10
                                                }
                                                MouseArea {
                                                    id: menuMouse
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    onClicked: root.notesMenuAction(modelData.act)
                                                }
                                            }
                                        }
                                    }
                                }

                                Column {
                                    id: notesCol
                                    anchors.left: parent.left; anchors.right: parent.right
                                    anchors.top: parent.top; anchors.topMargin: 32
                                    anchors.leftMargin: 12; anchors.rightMargin: 12
                                    spacing: 2

                                    Text {
                                        visible: root.notes.length === 0
                                        text: "Tiada nota"; color: "#5b6784"
                                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10
                                    }

                                    Repeater {
                                        model: root.notes
                                        delegate: Rectangle {
                                            required property int index
                                            required property var modelData
                                            width: notesCol.width; height: 22; radius: 5
                                            color: root.noteIndex === index ? "#182236" : "transparent"

                                            MouseArea {
                                                anchors.fill: parent
                                                onClicked: {
                                                    root.noteIndex = index
                                                    root.noteEdit = false
                                                }
                                            }

                                            Row {
                                                anchors.verticalCenter: parent.verticalCenter
                                                anchors.left: parent.left; anchors.leftMargin: 6
                                                anchors.right: parent.right; anchors.rightMargin: 6
                                                spacing: 6

                                                // kotak semak (hanya type "check")
                                                Rectangle {
                                                    visible: modelData.type === "check"
                                                    width: 12; height: 12; radius: 3
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    color: "transparent"; border.width: 1
                                                    border.color: modelData.done ? "#4fd1c5" : "#4a5774"
                                                    Text {
                                                        anchors.centerIn: parent
                                                        visible: modelData.done === true
                                                        text: "✓"; color: "#4fd1c5"
                                                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9
                                                    }
                                                    MouseArea {
                                                        anchors.fill: parent
                                                        onClicked: {
                                                            root.noteIndex = index
                                                            root.toggleNote(modelData.id)
                                                        }
                                                    }
                                                }

                                                Text {
                                                    visible: modelData.type !== "check"
                                                    text: "•"; color: "#5b6784"
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10
                                                }

                                                Text {
                                                    visible: !(root.noteEdit && root.noteIndex === index)
                                                    width: parent.width - (modelData.type === "check" ? 30 : 20)
                                                    text: String(modelData.text || "").length > 0 ? String(modelData.text) : "(kosong)"
                                                    color: modelData.done ? "#5b6784" : "#93a0be"
                                                    elide: Text.ElideRight
                                                    maximumLineCount: 1
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10
                                                }

                                                TextInput {
                                                    visible: root.noteEdit && root.noteIndex === index
                                                    width: parent.width - (modelData.type === "check" ? 30 : 20)
                                                    text: modelData.text || ""
                                                    color: "#eef3ff"
                                                    clip: true
                                                    selectByMouse: true
                                                    focus: visible
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10
                                                    Keys.onPressed: (e) => {
                                                        if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                                                            root.commitNote(modelData.id, text)
                                                            e.accepted = true
                                                        } else {
                                                            root.handleFieldKey(e)
                                                        }
                                                    }
                                                    onEditingFinished: {
                                                        if (!visible) return
                                                        if (text !== (modelData.text || "")) root.commitNote(modelData.id, text)
                                                        else root.noteEdit = false
                                                    }
                                                    Text {
                                                        visible: parent.text.length === 0
                                                        text: "Nota…"; color: "#5b6784"
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        font: parent.font
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    }
}

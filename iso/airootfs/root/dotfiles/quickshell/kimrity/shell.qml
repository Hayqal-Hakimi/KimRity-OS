// ~/.config/quickshell/kimrity/shell.qml
// KimRity menu v4: popup 900x560 — sidebar, 3 workspace clusters, apps in 2
// columns, recent files + notes. Flat, no decoration.
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import Quickshell.Io

ShellRoot {
    id: root

    property bool isOpen: false
    property int catIndex: -1      // -1 = all
    property int appIndex: 0
    property int wsIndex: 0
    property string filter: ""

    readonly property var cats: [
        "Development", "Web & Browser", "Security", "Engineering",
        "System", "Office", "Multimedia", "Utilities"
    ]

    // Workspace clusters — built from the user's conf (kimrity-ws) and real
    // icons (kimrity-icons). No hardcoded tool/glyph here.
    property var clusters: []
    property var iconMap: ({})
    property string wsText: ""
    property bool wsDone: false
    property bool iconsDone: false
    property bool wsMutating: false

    onIsOpenChanged: if (isOpen) root.refreshClusters()
    Component.onCompleted: root.refreshClusters()

    readonly property var allApps: [
        { n: "Firefox",    m: "FF", c: "#ff7139", cat: 1, cmd: "firefox" },
        { n: "nmap",       m: "nm", c: "#b57bff", cat: 2, cmd: "kitty -e bash -lc 'nmap; exec bash'" },
        { n: "VS Code",    m: "VS", c: "#3aa0ff", cat: 0, cmd: "code" },
        { n: "Wireshark",  m: "ws", c: "#6ea8fe", cat: 2, cmd: "wireshark" },
        { n: "Kitty",      m: "›_", c: "#7ee787", cat: 4, cmd: "kitty" },
        { n: "Burp Suite", m: "bp", c: "#ff8b5e", cat: 2, cmd: "burpsuite" },
        { n: "btop",       m: "bt", c: "#f5c451", cat: 4, cmd: "kitty -e btop" },
        { n: "qemu",       m: "qz", c: "#9ad0ff", cat: 3, cmd: "kitty -e bash -lc 'ls ~/vm; exec bash'" },
        { n: "yazi",       m: "yz", c: "#d6a2ff", cat: 4, cmd: "kitty -e yazi" },
        { n: "ghidra",     m: "gd", c: "#ff9f6e", cat: 2, cmd: "ghidra" },
        { n: "metasploit", m: "ms", c: "#ff6b6b", cat: 2, cmd: "kitty -e msfconsole" },
        { n: "radare2",    m: "r2", c: "#8be9fd", cat: 2, cmd: "kitty -e r2 -" }
    ]

    readonly property var apps: {
        let l = allApps
        if (catIndex >= 0) l = l.filter(a => a.cat === catIndex)
        if (filter.length > 0) l = l.filter(a => a.n.toLowerCase().includes(filter.toLowerCase()))
        return l
    }

    readonly property var recent: [
        { n: "report-gate-2026-10.md", p: "~/Documents/kimrity · 20:41" },
        { n: "hyprland.conf",          p: "~/.config/hypr · 20:32" },
        { n: "audit.log",              p: "/var/log/audit · 18:04" },
        { n: "shell.qml",              p: "~/.config/quickshell/kimrity · 19:57" }
    ]

    readonly property var notes: [
        "☐ Record the Gate verdict",
        "☑ 12 audit rules active",
        "☐ SOC L1 report (day 3)",
        "☐ Check the SUPER+F1…F3 keybinds"
    ]

    // ---------------- preset settings ----------------
    property bool setOpen: false
    property string editPreset: ""
    property var editRows: []
    property int newWs: 1
    property var tools: []
    property var toolHits: []
    readonly property string homeDir: Quickshell.env("HOME") || "/home/hayqal"
    readonly property string confPath: homeDir + "/.config/kimrity/workspaces.conf"

    // Scripts print the full file to stdout; the UI reads from there (no cache).
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

    // Full conf for clusters (not the editor). kimrity-ws needs the preset
    // argument even for `list`; `list` ignores it and prints all rows.
    Process {
        id: wsListProc
        stdout: StdioCollector {
            id: wsListOut
            onStreamFinished: root.wsListReady(wsListOut.text)
        }
        onExited: if (!root.wsDone) root.wsListReady("")
    }

    // Map tool -> real icon path.
    Process {
        id: iconsProc
        stdout: StdioCollector {
            id: iconsOut
            onStreamFinished: root.iconsReady(iconsOut.text)
        }
        onExited: if (!root.iconsDone) root.iconsReady("")
    }

    // List of tools that actually exist (1-day cache) for the dropdown.
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

    function loadTools() {
        if (root.tools.length > 0) return
        toolsProc.command = [root.homeDir + "/.local/bin/kimrity-tools"]
        toolsProc.running = true
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

    // Reload clusters + icons. Called when the menu opens, after edits, and
    // after apply so the panel never shows stale data.
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

        // The presets are always these three, in this order; rows sort by workspace.
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

    // Maximum 4 tiles: 3 tools + one "+N" tile when there are more.
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
        function wsApply(key: string, rowNo: string, ws: string): void {
            root.isOpen = true
            if (root.editPreset !== key) root.openEditor(key)
            root.wsCall(["set", key, rowNo, ws])
        }
    }

    Process { id: runner; onExited: root.isOpen = false }

    function run(cmd) {
        if (!cmd) return
        runner.command = ["bash", "-lc", cmd]
        runner.running = true
        root.isOpen = false
    }

    function handleFieldKey(e) {
        if (e.key === Qt.Key_Escape || e.key === Qt.Key_F1
                || e.key === Qt.Key_F2 || e.key === Qt.Key_F3)
            root.handleKey(e)
    }

    function handleKey(e) {
        switch (e.key) {
        case Qt.Key_Escape:
            root.isOpen = false; e.accepted = true; break
        case Qt.Key_F1: root.run("$HOME/.local/bin/workspace-launch F1"); e.accepted = true; break
        case Qt.Key_F2: root.run("$HOME/.local/bin/workspace-launch F2"); e.accepted = true; break
        case Qt.Key_F3: root.run("$HOME/.local/bin/workspace-launch F3"); e.accepted = true; break
        case Qt.Key_Down:  root.appIndex = Math.min(root.appIndex + 2, root.apps.length - 1); e.accepted = true; break
        case Qt.Key_Up:    root.appIndex = Math.max(root.appIndex - 2, 0); e.accepted = true; break
        case Qt.Key_Right: root.appIndex = Math.min(root.appIndex + 1, root.apps.length - 1); e.accepted = true; break
        case Qt.Key_Left:  root.appIndex = Math.max(root.appIndex - 1, 0); e.accepted = true; break
        case Qt.Key_Return:
        case Qt.Key_Enter:
            if (root.apps[root.appIndex]) root.run(root.apps[root.appIndex].cmd)
            e.accepted = true; break
        }
    }

    // ---------------- window ----------------
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

                // ================= preset settings editor =================
                Rectangle {
                    id: editor
                    visible: root.editPreset !== ""
                    z: 10
                    x: 184; y: 8
                    width: parent.width - 192
                    height: parent.height - 16
                    radius: 11; color: "#101728"

                    // Swallow empty clicks so they do not fall through to the dashboard behind.
                    MouseArea { anchors.fill: parent; onClicked: {} }

                    Column {
                        anchors.fill: parent
                        anchors.margins: 14
                        spacing: 8

                        Row {
                            width: parent.width
                            spacing: 12
                            Text {
                                text: "Settings · " + root.editPreset + " " + (root.clusters[root.wsIndex] ? root.clusters[root.wsIndex].label : "")
                                color: "#e3ebff"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 13
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Rectangle {
                                width: 150; height: 28; radius: 7
                                color: "#12343a"; border.color: "#2f6f69"; border.width: 1
                                anchors.verticalCenter: parent.verticalCenter
                                Text {
                                    anchors.centerIn: parent
                                    text: "All → Tab 1"; color: "#4fd1c5"
                                    font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: root.wsCall(["all", root.editPreset, "1"])
                                }
                            }

                            Rectangle {
                                width: 82; height: 28; radius: 7
                                color: "#182236"
                                anchors.verticalCenter: parent.verticalCenter
                                Text {
                                    anchors.centerIn: parent
                                    text: "Back"; color: "#c3cde6"
                                    font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10
                                }
                                MouseArea { anchors.fill: parent; onClicked: root.editPreset = "" }
                            }
                        }

                        Text {
                            text: "Number = workspace. Same number = same tab. Click to change."
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
                                text: "CMD / LINK"; color: "#5f6c8c"
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
                                            text: "Remove"; color: "#e08b95"
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
                                            text: "tool — e.g.: firefox"
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
                                            text: "cmd / link — e.g.: https://youtube.com"
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
                                        text: "＋ Add"; color: "#06221f"
                                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11
                                        font.bold: true
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: {
                                            let t = addTool.text.trim()
                                            let a = addArgs.text.trim()
                                            // split off a link accidentally typed into the tool box
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

                            // dropdown of tools that are actually installed
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
                                color: root.catIndex === -1 ? "#182236" : "transparent"
                                Rectangle {
                                    width: 2; height: parent.height - 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: "#4fd1c5"; visible: root.catIndex === -1
                                }
                                Row {
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.left: parent.left; anchors.leftMargin: 9
                                    spacing: 8
                                    Text { text: "\uf00a"; color: root.catIndex === -1 ? "#4fd1c5" : "#66738f"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11 }
                                    Text { text: "Quick access"; color: root.catIndex === -1 ? "#e7eeff" : "#93a1c0"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11 }
                                }
                                MouseArea { anchors.fill: parent; onClicked: { root.catIndex = -1; root.appIndex = 0 } }
                            }

                            // --- dropdown: preset settings ---
                            Rectangle {
                                width: parent.width; height: 26; radius: 6; color: "transparent"
                                Row {
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.left: parent.left; anchors.leftMargin: 9
                                    spacing: 8
                                    Text { text: "\uf013"; color: "#66738f"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11 }
                                    Text { text: "Preset settings"; color: "#93a1c0"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11 }
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

                            Repeater {
                                model: root.cats
                                delegate: Rectangle {
                                    required property int index
                                    required property var modelData
                                    width: parent.width; height: 26; radius: 6
                                    color: root.catIndex === index ? "#182236" : "transparent"
                                    Row {
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.left: parent.left; anchors.leftMargin: 9
                                        spacing: 8
                                        Text { text: "\uf105"; color: "#66738f"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10 }
                                        Text {
                                            text: modelData
                                            color: root.catIndex === index ? "#e7eeff" : "#93a1c0"
                                            font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11
                                        }
                                    }
                                    MouseArea { anchors.fill: parent; onClicked: { root.catIndex = index; root.appIndex = 0 } }
                                }
                            }

                            // push the rest to the bottom
                            Item { width: 1; height: Math.max(0, parent.height - 30 - 4 - 28 - 26 - root.cats.length * 26 - 26 - 4 - (root.setOpen ? 100 : 0)) }

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
                        }
                    }

                    // ================= main column =================
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
                                text: "F1–F3: launch every app into workspace 1–3"
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

                                                // One row -> one big tile; otherwise 2x2.
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

                                                                    // Monogram fallback — only when there is no icon.
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

                                                                    // Tool name inside the tile (2x2): the 96px space
                                                                    // is not enough for a 34px tile + an outer caption.
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

                                                                // One row: name under the big tile.
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

                        // ----- apps in 2 columns -----
                        Rectangle {
                            width: parent.width; height: 232
                            radius: 11; color: "#101728"

                            Text { x: 12; y: 10; text: "Apps"; color: "#b9c6e2"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11 }
                            Text {
                                anchors.right: parent.right; anchors.rightMargin: 12; y: 11
                                text: root.apps.length + " apps · 2 columns"
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

                                        Row {
                                            anchors.verticalCenter: parent.verticalCenter
                                            anchors.left: parent.left; anchors.leftMargin: 6
                                            spacing: 8
                                            Rectangle {
                                                width: 18; height: 18; radius: 4; color: modelData.c
                                                Text {
                                                    anchors.centerIn: parent
                                                    text: modelData.m; color: "#0a0f1e"
                                                    font.family: "JetBrainsMono Nerd Font"
                                                    font.pixelSize: 8; font.bold: true
                                                }
                                            }
                                            Text {
                                                text: modelData.n; color: "#c3cde6"
                                                font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11
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

                                Rectangle {
                                    anchors.right: parent.right; anchors.rightMargin: 12; y: 9
                                    width: 52; height: 16; radius: 8
                                    color: "transparent"; border.width: 1; border.color: "#2f6f69"
                                    Text {
                                        anchors.centerIn: parent
                                        text: "AI · live"; color: "#4fd1c5"
                                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9
                                    }
                                }

                                Column {
                                    anchors.left: parent.left
                                    anchors.top: parent.top; anchors.topMargin: 34
                                    anchors.leftMargin: 12
                                    spacing: 5
                                    Repeater {
                                        model: root.notes
                                        delegate: Text {
                                            required property var modelData
                                            text: modelData; color: "#93a0be"
                                            font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10
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

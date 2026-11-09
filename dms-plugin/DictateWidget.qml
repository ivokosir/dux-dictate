import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.DCommon.Widgets
import qs.Modules.Plugins

// One bar button, two modes. In the popout, click the title to switch.
//
//   Dictate   talk and the text is pasted         (the `dictate` daemon)
//   Meeting   record your mic + what you hear     (the `meetrec` script)
//
// Click the bar button for the popout, right click starts/stops the current mode.
// The popout header is the same row in both modes:
//   [icon] Title ⇅ 0:12 ................. [the mode's buttons]
// and under it the mode's files (Recent takes / Recordings).
PluginComponent {
    id: root

    layerNamespacePlugin: "dictate"

    // ---- mode ------------------------------------------------------------------------

    property string mode: "dictate"
    readonly property bool meeting: mode === "meeting"
    readonly property bool popoutOpen: interactionActive
    readonly property bool dictOpen: popoutOpen && !meeting
    readonly property bool meetOpen: popoutOpen && meeting

    function setMode(m) {
        m = m === "meeting" ? "meeting" : "dictate";
        if (m === root.mode)
            return;
        root.mode = m;
        meet.editingPath = "";
        dict.confirmClear = false;
        if (root.pluginService && root.pluginId)
            root.pluginService.savePluginState(root.pluginId, "mode", m);
    }

    // The mode is remembered (and shared by the bars on every screen).
    function loadMode() {
        if (!root.pluginService || !root.pluginId)
            return;
        const m = root.pluginService.loadPluginState(root.pluginId, "mode", "dictate");
        root.mode = m === "meeting" ? "meeting" : "dictate";
    }

    Component.onCompleted: loadMode()
    onPluginIdChanged: loadMode()
    onPluginServiceChanged: loadMode()

    Connections {
        target: root.pluginService
        function onPluginStateChanged(id) {
            if (id === root.pluginId)
                root.loadMode();
        }
    }

    // Open the popout in a mode; if it is open in the other one, just switch.
    function openAs(m) {
        const switching = root.mode !== m;
        root.setMode(m);
        if (!(root.popoutOpen && switching))
            root.triggerPopout();
    }

    // Dictate: the card steps aside, and finishing copies instead of pasting.
    onDictOpenChanged: {
        dict.run(["popout", dictOpen ? "on" : "off"]);
        if (dictOpen) {
            dict.confirmClear = false;
            dict.refreshList();
        }
    }

    onMeetOpenChanged: {
        if (meetOpen) {
            meet.refreshStatus();
            meet.refreshList();
            meet.refreshSize();
        }
    }

    // Closing the popout drops a half-typed meeting name.
    onPopoutOpenChanged: {
        if (!popoutOpen)
            meet.editingPath = "";
    }

    pillRightClickAction: () => root.meeting ? meet.toggle() : dict.run(["toggle"])

    // dms ipc call dictate popout | switchMode   (e.g. for a keybind)
    IpcHandler {
        target: "dictate"

        function popout(): string {
            root.openAs("dictate");
            return "ok";
        }

        function switchMode(): string {
            root.setMode(root.meeting ? "dictate" : "meeting");
            return root.mode;
        }
    }

    // dms ipc call meetrec toggle | open | rename
    IpcHandler {
        target: "meetrec"

        function toggle(): string {
            meet.toggle();
            return meet.recording ? "stopping" : "starting";
        }

        function open(): string {
            root.openAs("meeting");
            return "ok";
        }

        // Jump straight to naming: the current meeting, or else the newest one.
        function rename(): string {
            const path = meet.recording ? meet.st.file : (meet.recordings.length > 0 ? meet.recordings[0].path : "");
            if (path === "")
                return "nothing to rename";
            root.setMode("meeting");
            meet.editingPath = path;
            if (!root.popoutOpen)
                root.triggerPopout();
            return "ok";
        }
    }

    // ---- shared helpers ----------------------------------------------------------------

    property real nowMs: Date.now()
    property string toast: ""
    property string lastToast: ""
    readonly property color recColor: "#d32f2f"

    function clock(ms) {
        const s = Math.max(0, Math.floor(ms / 1000));
        const h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, x = s % 60;
        const pad = n => String(n).padStart(2, "0");
        return (h > 0 ? h + ":" + pad(m) : m) + ":" + pad(x);
    }

    function fmtSize(b) {
        b = Number(b) || 0;
        if (b < 1024 * 1024)
            return Math.max(1, Math.round(b / 1024)) + " KB";
        return (b / 1024 / 1024).toFixed(1) + " MB";
    }

    // "Today 14:31" / "Yesterday 18:20" / "8 Nov 09:12"
    function dayLabel(d) {
        const now = new Date();
        const hm = Qt.formatTime(d, "HH:mm");
        if (d.toDateString() === now.toDateString())
            return "Today " + hm;
        const y = new Date(now);
        y.setDate(now.getDate() - 1);
        if (d.toDateString() === y.toDateString())
            return "Yesterday " + hm;
        return Qt.formatDate(d, "d MMM") + " " + hm;
    }

    function showToast(text) {
        root.toast = text;
        root.lastToast = text;
        toastTimer.restart();
    }

    Timer {
        id: toastTimer
        interval: 1800
        onTriggered: root.toast = ""
    }

    // Ticks only while something is being recorded.
    Timer {
        interval: dict.recording ? 500 : 1000
        repeat: true
        running: dict.recording || meet.recording
        triggeredOnStart: true
        onTriggered: root.nowMs = Date.now()
    }

    // ---- Dictate: state from `dictate watch`, takes are files in ~/Music/Dictations ----

    Item {
        id: dict

        readonly property string bin: Quickshell.env("HOME") + "/.local/bin/dictate"
        property var st: ({ daemon: false })

        readonly property bool up: st.daemon === true
        readonly property string phase: up ? (st.state || "idle") : "down"
        readonly property bool recording: phase === "recording"
        readonly property bool busy: phase === "transcribing" || phase === "cleaning"
        readonly property bool problem: phase === "problem"
        readonly property var problemIcon: ({ mic: "mic_off", eleven: "cloud_off", nokey: "key_off" })
        readonly property bool barError: problem && !!problemIcon[st.problem]
        readonly property bool active: recording || busy || barError
        readonly property string elapsed: recording ? root.clock(root.nowMs - (Number(st.started_ms) || root.nowMs)) : ""

        // [icon, title, hint]
        readonly property var problemInfo: ({
            cleanfail: ["auto_awesome", "Clean-up failed", "Raw text used instead"],
            paste: ["content_paste", "Couldn't paste", "It's on your clipboard"],
            nospeech: ["voice_over_off", "No speech heard", ""],
            mic: ["mic_off", "Mic not working", "Check the input device"],
            eleven: ["cloud_off", "Didn't go through", "Audio is saved. Retry sends it again"],
            livefail: ["cloud_off", "Live stopped", "The full text is on your clipboard"],
            cleancopied: ["auto_awesome", "Cleaned & copied", "The raw text was typed live; the cleaned one is on your clipboard"],
            nokey: ["key_off", "No API key", "Add your ElevenLabs key: dictate set-key"],
            other: ["error", "Something failed", ""]
        })

        property var takes: []
        property bool showAll: false
        property bool confirmClear: false
        // stamp -> "transcribe" | "clean" while a row is working
        property var rowBusy: ({})
        // ✨/✓ pressed in the popout: say "Copied" when it is done.
        property bool finishingHere: false
        property var _files: -1

        readonly property var visibleTakes: takes.filter(t => t.stamp !== st.current)

        function run(args) {
            Quickshell.execDetached([dict.bin].concat(args));
        }

        onStChanged: {
            if (root.dictOpen && dict.st.files !== dict._files)
                dict.refreshList();
            dict._files = dict.st.files;
            if (dict.finishingHere && dict.phase === "idle") {
                dict.finishingHere = false;
                root.showToast("Copied");
            } else if (dict.finishingHere && dict.phase === "problem") {
                dict.finishingHere = false;
            }
        }

        Process {
            id: watcher
            command: [dict.bin, "watch"]
            running: true
            stdout: SplitParser {
                onRead: data => {
                    // Mic level lines ("L 0.42") are only for the card.
                    if (data.charCodeAt(0) === 76)
                        return;
                    try {
                        dict.st = JSON.parse(data);
                    } catch (e) {}
                }
            }
            onExited: {
                dict.st = { daemon: false };
                restartWatcher.start();
            }
        }

        Timer {
            id: restartWatcher
            interval: 2000
            onTriggered: watcher.running = true
        }

        function refreshList() {
            Proc.runCommand(null, [dict.bin, "list", "20"], (out, code) => {
                try {
                    dict.takes = JSON.parse(out.trim());
                } catch (e) {}
            }, 0, 10000, root);
        }

        function setBusy(stamp, what) {
            const b = Object.assign({}, dict.rowBusy);
            if (what)
                b[stamp] = what;
            else
                delete b[stamp];
            dict.rowBusy = b;
        }

        function rowAction(stamp, cmd, okText) {
            dict.setBusy(stamp, cmd);
            Proc.runCommand(null, [dict.bin, cmd, stamp], (out, code) => {
                dict.setBusy(stamp, "");
                root.showToast(code === 0 ? okText : "Failed");
                dict.refreshList();
            }, 0, 300000, root);
        }

        function copyTake(t, which) {
            Proc.runCommand(null, [dict.bin, "copy", t.stamp, which], (out, code) => {
                root.showToast(code !== 0 ? "Failed" : which === "clean" ? "Cleaned text copied" : "Copied");
            }, 0, 10000, root);
        }

        // "2026-11-09_14-31-02" -> "Today 14:31"
        function whenOf(stamp) {
            const m = String(stamp).match(/^(\d{4})-(\d\d)-(\d\d)_(\d\d)-(\d\d)/);
            if (!m)
                return stamp;
            return root.dayLabel(new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]));
        }
    }

    // ---- Meeting: all the work is done by `meetrec`, files are in ~/Music/Meetings ----

    Item {
        id: meet

        readonly property string bin: Quickshell.env("HOME") + "/.local/bin/meetrec"
        readonly property string runDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/meetrec"
        // meetrec keeps "<file>\n<start ms>" in this file while recording and
        // empties it when recording ends, so watching it replaces polling.
        readonly property string stateFile: runDir + "/current"

        property var st: ({ recording: false })
        property var recordings: []
        property bool busy: false
        // Path of the recording whose name is being edited ("" = none).
        property string editingPath: ""
        // Scroll position of the list, kept when the list reloads.
        property real listY: 0
        property real keepY: 0

        readonly property bool recording: st.recording === true
        readonly property string elapsed: recording ? root.clock(root.nowMs - Number(st.started || root.nowMs)) : ""
        readonly property string currentLabel: recording ? labelFromName(String(st.file || "").split("/").pop()) : ""

        function run(args, cb) {
            Proc.runCommand(null, [meet.bin].concat(args), (stdout, code) => {
                if (cb)
                    cb(stdout, code);
            }, 0, 30000, root);
        }

        function applyState(text) {
            const lines = String(text || "").trim().split("\n");
            const file = lines[0] || "";
            const was = meet.recording;
            meet.st = file === "" ? { recording: false } : {
                recording: true,
                file: file,
                started: Number(lines[1]) || Date.now(),
                size: meet.st.file === file ? meet.st.size : 0
            };
            root.nowMs = Date.now();
            if (was !== meet.recording)
                meet.refreshList();
        }

        function refreshStatus() {
            stateView.reload();
        }

        // Only while the popout is open: the size of the file being recorded.
        function refreshSize() {
            if (!meet.recording)
                return;
            const file = meet.st.file;
            Proc.runCommand(null, ["stat", "-c", "%s", file], (out, code) => {
                if (code === 0 && meet.st.file === file) {
                    const st = Object.assign({}, meet.st);
                    st.size = Number(out.trim()) || 0;
                    meet.st = st;
                }
            }, 0, 5000, root);
        }

        function refreshList() {
            meet.run(["list"], (out, code) => {
                try {
                    const items = JSON.parse(out.trim());
                    meet.keepY = meet.listY;
                    meet.recordings = items;
                } catch (e) {}
            });
        }

        function toggle() {
            if (meet.busy)
                return;
            meet.busy = true;
            meet.run([meet.recording ? "stop" : "start"], () => {
                meet.busy = false;
                meet.refreshStatus();
                meet.refreshList();
            });
        }

        function transcribe(item) {
            meet.run(["transcribe", item.path], (out, code) => {
                root.showToast(code === 0 ? "Transcribing…" : "No ElevenLabs key");
                meet.refreshList();
            });
        }

        function act(cmd, path, message) {
            meet.run([cmd, path], (out, code) => {
                if (message)
                    root.showToast(code === 0 ? message : "Failed");
            });
        }

        function commitRename(path, name) {
            meet.editingPath = "";
            if (String(name).trim() === "")
                return;
            meet.run(["rename", path, name], (out, code) => {
                root.showToast(code === 0 ? "Renamed" : "Rename failed");
                meet.refreshStatus();
                meet.refreshList();
            });
        }

        // When the recording started: "Today 13:38" / "9 Nov 13:38"
        function whenOf(item) {
            return root.dayLabel(new Date(Number(item.mtime) * 1000 - Number(item.duration || 0) * 1000));
        }

        // The name is the file name after the date, exactly as it is on disk.
        function labelFromName(fileName) {
            const base = String(fileName).replace(/\.[^.]+$/, "");
            const m = base.match(/^\d{4}-\d\d-\d\d_\d\d-\d\d(?:-\d\d)?_(.*)$/);
            return m ? m[1] : base;
        }

        function labelOf(item) {
            return meet.labelFromName(item.name);
        }

        FileView {
            id: stateView
            path: meet.stateFile
            watchChanges: true
            printErrors: false
            blockLoading: false
            onFileChanged: reload()
            onLoaded: meet.applyState(text())
            onLoadFailed: meet.applyState("")
        }

        // meetrec rewrites this file when a transcription starts or ends.
        FileView {
            path: meet.runDir + "/events"
            watchChanges: true
            printErrors: false
            blockLoading: false
            onFileChanged: meet.refreshList()
        }

        // The files must exist for the watchers to see them change.
        Component.onCompleted: {
            Proc.runCommand(null, ["sh", "-c", "mkdir -p \"$1\" && touch \"$1/current\" \"$1/events\"", "sh", meet.runDir], () => {
                stateView.reload();
                meet.refreshList();
            }, 0, 5000, root);
        }
    }

    // ---- bar pill ----------------------------------------------------------------------
    //
    //   idle       the mode's icon (mic / ◉)
    //   dictating  teal fill, mic, timer
    //   meeting    red fill, ◉ (or the mic while you also dictate), the meeting's timer

    readonly property bool pillTimer: dict.recording || meet.recording
    // The mic shows dictation; ◉ shows the meeting.
    readonly property bool pillMic: dict.active || (!meet.recording && !root.meeting)

    // Plugins can't colour the pill itself, so this fills it from inside.
    component PillFill: Rectangle {
        property Item content
        readonly property Item box: content && content.parent ? content.parent.parent : null
        anchors.centerIn: parent
        visible: root.pillTimer
        width: box ? box.width : content.width + 16
        height: box ? box.height : root.widgetThickness
        radius: Theme.cornerRadius
        color: meet.recording ? root.recColor : Theme.withAlpha(Theme.primary, 0.16)
    }

    component PillIcon: DIcon {
        name: !root.pillMic ? "radio_button_checked"
            : dict.phase === "down" ? "mic_off"
            : dict.barError ? dict.problemIcon[dict.st.problem] : "mic"
        filled: root.pillMic ? dict.active : meet.recording
        size: root.iconSize
        color: meet.recording ? "white"
            : !root.pillMic ? (Theme.widgetTextColor || Theme.surfaceText)
            : dict.phase === "down" ? Theme.surfaceVariantText
            : dict.barError ? Theme.error
            : (dict.recording || dict.busy) ? Theme.primary
            : (Theme.widgetTextColor || Theme.surfaceText)
        opacity: root.pillMic ? (dict.busy ? 0.55 : 1) : (meet.recording ? 1 : 0.7)
    }

    component PillTime: StyledText {
        visible: root.pillTimer
        text: meet.recording ? meet.elapsed : dict.elapsed
        font.pixelSize: Theme.fontSizeSmall
        font.features: { "tnum": 1 }
        color: meet.recording ? "white" : Theme.primary
    }

    horizontalBarPill: Component {
        Item {
            id: hp
            implicitWidth: hRow.implicitWidth
            implicitHeight: hRow.implicitHeight

            PillFill {
                content: hp
            }
            Row {
                id: hRow
                anchors.centerIn: parent
                spacing: 4
                PillIcon {
                    anchors.verticalCenter: parent.verticalCenter
                }
                PillTime {
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }

    verticalBarPill: Component {
        Item {
            id: vp
            implicitWidth: vCol.implicitWidth
            implicitHeight: vCol.implicitHeight

            PillFill {
                content: vp
            }
            Column {
                id: vCol
                anchors.centerIn: parent
                PillIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                }
                PillTime {
                    font.pixelSize: Theme.fontSizeSmall - 2
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }
    }

    // ---- popout building blocks ----------------------------------------------------------

    component IconBtn: DActionButton {
        property string tip: ""
        iconSize: 18
        iconColor: Theme.surfaceVariantText
        buttonSize: 32
        tooltipText: tip !== "" ? tip : null
        tooltipSide: "top"
    }

    // Filled pill button (Start, Record, Stop, Retry) or ghost (Cancel).
    component PillBtn: Rectangle {
        id: pb
        property string label
        property string icon: ""
        property color tint: Theme.primary
        property color onTint: Theme.onPrimary
        property bool ghost: false
        property bool off: false
        readonly property color fg: ghost ? Theme.surfaceVariantText : onTint
        signal clicked
        implicitHeight: 36
        implicitWidth: pbRow.implicitWidth + Theme.spacingL * 2
        radius: height / 2
        opacity: off ? 0.38 : 1
        color: ghost ? (pbArea.containsMouse && !off ? Theme.withAlpha(Theme.surfaceText, 0.08) : "transparent")
                     : (pbArea.containsMouse && !off ? Qt.lighter(tint, 1.1) : tint)
        Row {
            id: pbRow
            anchors.centerIn: parent
            spacing: 6
            DIcon {
                visible: pb.icon !== ""
                name: pb.icon
                size: 18
                filled: true
                color: pb.fg
                anchors.verticalCenter: parent.verticalCenter
            }
            StyledText {
                text: pb.label
                color: pb.fg
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                anchors.verticalCenter: parent.verticalCenter
            }
        }
        MouseArea {
            id: pbArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: pb.off ? Qt.ArrowCursor : Qt.PointingHandCursor
            onClicked: if (!pb.off) pb.clicked()
        }
    }

    // "Copied", "Moved to trash": fades in place, nothing moves.
    component ToastChip: Rectangle {
        anchors.centerIn: parent
        width: toastRow.implicitWidth + Theme.spacingL * 2
        height: 26
        radius: 13
        color: Theme.withAlpha(Theme.success, 0.15)
        opacity: root.toast !== "" ? 1 : 0
        visible: opacity > 0
        Behavior on opacity {
            NumberAnimation { duration: 150 }
        }
        Row {
            id: toastRow
            anchors.centerIn: parent
            spacing: 6
            DIcon {
                name: "check_circle"
                size: 16
                color: Theme.success
                anchors.verticalCenter: parent.verticalCenter
            }
            StyledText {
                // Keep the last text while fading out.
                text: root.toast !== "" ? root.toast : root.lastToast
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    // One dictation take.
    component TakeRow: Item {
        id: tr
        property var take
        readonly property bool hovered: rowHover.hovered
        readonly property string work: dict.rowBusy[take.stamp] || ""
        readonly property bool audioOnly: !take.transcribed

        width: parent ? parent.width : 0
        height: 54

        HoverHandler {
            id: rowHover
        }

        Rectangle {
            anchors.fill: parent
            radius: Theme.cornerRadius
            color: Theme.surfaceText
            opacity: !tr.audioOnly && rowMouse.pressed ? 0.1 : tr.hovered && !tr.audioOnly ? 0.05 : 0
        }

        // Click copies the best text (cleaned if there is one).
        MouseArea {
            id: rowMouse
            anchors.fill: parent
            enabled: !tr.audioOnly && tr.work === ""
            cursorShape: Qt.PointingHandCursor
            onClicked: dict.copyTake(tr.take, tr.take.cleaned ? "clean" : "raw")
        }

        Rectangle {
            id: rowIcon
            x: Theme.spacingS
            width: 36
            height: 36
            radius: 18
            anchors.verticalCenter: parent.verticalCenter
            color: tr.work !== "" ? Theme.withAlpha(Theme.primary, 0.14) : tr.audioOnly ? Theme.withAlpha(Theme.error, 0.1) : Theme.surfaceContainerHigh

            DSpinner {
                anchors.fill: parent
                size: 36
                strokeWidth: 2
                color: Theme.primary
                visible: tr.work !== ""
                running: visible
            }
            DIcon {
                anchors.centerIn: parent
                name: tr.work === "clean" ? "auto_awesome" : tr.work !== "" || tr.audioOnly ? "graphic_eq" : tr.take.cleaned ? "auto_awesome" : "notes"
                size: 18
                color: tr.work !== "" ? Theme.primary : tr.audioOnly ? Theme.error : Theme.surfaceVariantText
            }
        }

        Column {
            anchors.left: rowIcon.right
            anchors.leftMargin: Theme.spacingM
            anchors.right: rowActions.visible ? rowActions.left : parent.right
            anchors.rightMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            StyledText {
                width: parent.width
                text: tr.audioOnly ? "Not transcribed" : (tr.take.cleaned ? tr.take.clean : tr.take.text)
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontSizeMedium
                font.italic: tr.audioOnly
                color: tr.audioOnly ? Theme.surfaceVariantText : Theme.surfaceText
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
            }
            StyledText {
                width: parent.width
                text: dict.whenOf(tr.take.stamp) + " · " + root.clock(tr.take.secs * 1000)
                    + (tr.work === "transcribe" ? " · transcribing…" : tr.work === "clean" ? " · cleaning up…" : "")
                font.pixelSize: Theme.fontSizeSmall
                font.features: { "tnum": 1 }
                color: Theme.surfaceVariantText
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
            }
        }

        // Same buttons on every transcribed row; only the tooltip changes.
        Row {
            id: rowActions
            visible: tr.work === "" && (tr.hovered || tr.audioOnly)
            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingXS
            anchors.verticalCenter: parent.verticalCenter

            IconBtn {
                visible: tr.audioOnly
                iconName: "refresh"
                tip: "Transcribe"
                onClicked: dict.rowAction(tr.take.stamp, "transcribe", "Transcribed")
            }
            IconBtn {
                visible: !tr.audioOnly
                iconName: "auto_awesome"
                tip: tr.take.cleaned ? "Copy cleaned text" : "Clean up"
                onClicked: tr.take.cleaned ? dict.copyTake(tr.take, "clean") : dict.rowAction(tr.take.stamp, "clean", "Cleaned up")
            }
            IconBtn {
                visible: !tr.audioOnly
                iconName: "content_copy"
                tip: "Copy raw text"
                onClicked: dict.copyTake(tr.take, "raw")
            }
            IconBtn {
                iconName: "folder_open"
                tip: "Show in folder"
                onClicked: {
                    dict.run(["reveal", tr.take.stamp]);
                    root.closePopout();
                }
            }
            IconBtn {
                iconName: "delete"
                tip: "Delete (to trash)"
                onClicked: Proc.runCommand(null, [dict.bin, "trash", tr.take.stamp], (out, code) => {
                    root.showToast(code === 0 ? "Moved to trash" : "Delete failed");
                    dict.refreshList();
                }, 0, 10000, root)
            }
        }
    }

    // Inline name editor for a meeting: Enter saves, Escape cancels.
    component NameEdit: DTextField {
        id: ne

        property string path
        property string initial

        text: initial
        showAcceptButton: true
        onAccepted: meet.commitRename(ne.path, ne.text)
        Keys.onEscapePressed: event => {
            meet.editingPath = "";
            event.accepted = true;
        }
        Component.onCompleted: {
            ne.forceActiveFocus();
            ne.selectAll();
        }

        // Opened from a keybind, the popout gets keyboard focus a moment after
        // this field exists, so keep asking until the field really has it.
        Timer {
            property int tries: 0
            interval: 50
            repeat: true
            running: !ne.inputFocused && tries < 20
            onTriggered: {
                tries++;
                ne.forceActiveFocus();
                ne.selectAll();
            }
        }
    }

    // One meeting recording.
    component MeetRow: Item {
        id: rr

        property var item
        readonly property bool hovered: rowHover.hovered
        readonly property bool editing: meet.editingPath === item.path

        width: parent ? parent.width : 0
        height: 54

        HoverHandler {
            id: rowHover
        }

        Rectangle {
            anchors.fill: parent
            radius: Theme.cornerRadius
            color: Theme.surfaceText
            opacity: rowMouse.pressed ? 0.1 : rr.hovered ? 0.05 : 0
        }

        // Clicking a row opens it in the player.
        MouseArea {
            id: rowMouse
            anchors.fill: parent
            enabled: !rr.editing
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                meet.act("open", rr.item.path);
                root.closePopout();
            }
        }

        Rectangle {
            id: rowIcon
            x: Theme.spacingS
            width: 36
            height: 36
            radius: 18
            color: Theme.surfaceContainerHigh
            anchors.verticalCenter: parent.verticalCenter

            DIcon {
                anchors.centerIn: parent
                name: "graphic_eq"
                size: 18
                color: Theme.surfaceVariantText
            }
        }

        Column {
            anchors.left: rowIcon.right
            anchors.leftMargin: Theme.spacingM
            anchors.right: parent.right
            anchors.rightMargin: rowActions.visible ? rowActions.width + Theme.spacingS : Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Loader {
                active: rr.editing
                visible: active
                width: parent.width
                sourceComponent: NameEdit {
                    path: rr.item.path
                    initial: meet.labelOf(rr.item)
                }
            }

            StyledText {
                visible: !rr.editing
                width: parent.width
                text: meet.labelOf(rr.item) + " · " + meet.whenOf(rr.item)
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceText
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
            }

            Row {
                visible: !rr.editing
                width: parent.width
                spacing: 0

                StyledText {
                    id: rowInfo
                    text: root.clock(Number(rr.item.duration) * 1000) + " · " + root.fmtSize(rr.item.size) + (txState.text !== "" ? " · " : "")
                    font.pixelSize: Theme.fontSizeSmall
                    font.features: { "tnum": 1 }
                    color: Theme.surfaceVariantText
                    wrapMode: Text.NoWrap
                }

                // Transcript state; "Transcript" opens the text file.
                StyledText {
                    id: txState
                    readonly property bool hasText: rr.item.transcript !== ""
                    width: Math.min(implicitWidth, parent.width - rowInfo.width)
                    text: rr.item.tx === "running" ? "Transcribing…" : rr.item.tx === "failed" ? "Failed: " + rr.item.txError : hasText ? "Transcript" : ""
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontSizeSmall
                    font.underline: hasText && txMouse.containsMouse
                    color: rr.item.tx === "failed" ? Theme.error : rr.item.tx === "running" || hasText ? Theme.primary : Theme.surfaceVariantText
                    elide: Text.ElideRight
                    wrapMode: Text.NoWrap

                    MouseArea {
                        id: txMouse
                        anchors.fill: parent
                        enabled: txState.hasText && rr.item.tx !== "running"
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            meet.act("open", rr.item.transcript);
                            root.closePopout();
                        }
                    }
                }
            }
        }

        Row {
            id: rowActions
            visible: rr.hovered && !rr.editing
            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingXS
            anchors.verticalCenter: parent.verticalCenter

            IconBtn {
                iconName: "edit"
                tip: "Rename"
                onClicked: meet.editingPath = rr.item.path
            }

            // No transcript yet: make one. Have one: copy its text.
            IconBtn {
                visible: rr.item.tx !== "running"
                iconName: rr.item.transcript !== "" ? "text_snippet" : "subtitles"
                tip: rr.item.transcript !== "" ? "Copy transcript" : rr.item.tx === "failed" ? "Try transcribing again" : "Transcribe (ElevenLabs)"
                onClicked: {
                    if (rr.item.transcript !== "")
                        meet.act("copy-text", rr.item.path, "Transcript copied");
                    else
                        meet.transcribe(rr.item);
                }
            }

            IconBtn {
                iconName: "content_copy"
                tip: "Copy file"
                onClicked: meet.act("copy", rr.item.path, "File copied")
            }

            IconBtn {
                iconName: "folder_open"
                tip: "Show in folder"
                onClicked: {
                    meet.act("reveal", rr.item.path);
                    root.closePopout();
                }
            }

            IconBtn {
                iconName: "delete"
                tip: "Delete (to trash)"
                onClicked: meet.run(["delete", rr.item.path], (out, code) => {
                    root.showToast(code === 0 ? "Moved to trash" : "Delete failed");
                    meet.refreshList();
                })
            }
        }
    }

    // ---- popout --------------------------------------------------------------------------

    // Wide enough that every Dictate problem title fits next to ⚡ and the 120 px slot.
    popoutWidth: 430

    popoutContent: Component {
        PopoutComponent {
            id: popout

            Timer {
                interval: 2000
                repeat: true
                running: root.meetOpen && meet.recording
                onTriggered: meet.refreshSize()
            }

            Column {
                width: parent.width
                topPadding: Theme.spacingS
                bottomPadding: Theme.spacingS
                spacing: Theme.spacingS

                // Header: the same row in every mode and state.
                Item {
                    id: head
                    readonly property var prob: !root.meeting && dict.problem ? (dict.problemInfo[dict.st.problem] || dict.problemInfo.other) : null
                    readonly property bool notice: prob !== null && dict.st.problem === "cleancopied"
                    readonly property bool bad: prob !== null && !notice
                    readonly property bool down: !root.meeting && dict.phase === "down"
                    readonly property bool locked: dict.recording || dict.busy || !dict.up
                    readonly property bool renaming: root.meeting && meet.recording && meet.editingPath !== "" && meet.editingPath === meet.st.file

                    x: Theme.spacingS
                    width: parent.width - Theme.spacingS * 2
                    height: 44

                    Rectangle {
                        id: headIcon
                        width: 40
                        height: 40
                        radius: 20
                        anchors.verticalCenter: parent.verticalCenter
                        color: root.meeting ? (meet.recording ? root.recColor : Theme.surfaceContainerHigh)
                            : head.bad ? Theme.withAlpha(Theme.error, 0.14)
                            : (head.notice || dict.recording || dict.busy) ? Theme.withAlpha(Theme.primary, 0.16)
                            : Theme.surfaceContainerHigh

                        DSpinner {
                            anchors.fill: parent
                            size: 40
                            strokeWidth: 2
                            color: Theme.primary
                            visible: !root.meeting && dict.busy
                            running: visible && root.popoutOpen
                        }
                        DIcon {
                            anchors.centerIn: parent
                            name: root.meeting ? "radio_button_checked"
                                : head.prob ? head.prob[0]
                                : head.down ? "mic_off"
                                : dict.phase === "cleaning" ? "auto_awesome" : "mic"
                            filled: root.meeting ? meet.recording : true
                            size: 22
                            color: root.meeting ? (meet.recording ? "white" : Theme.surfaceVariantText)
                                : head.bad ? Theme.error
                                : (dict.recording || dict.busy || head.notice) ? Theme.primary
                                : Theme.surfaceVariantText
                        }
                    }

                    Column {
                        id: headCol
                        // The title button has 8 px of its own padding.
                        anchors.left: headIcon.right
                        anchors.leftMargin: Theme.spacingM - 8
                        anchors.right: headRight.left
                        anchors.rightMargin: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter

                        // Naming the meeting being recorded takes the whole spot.
                        Loader {
                            active: head.renaming
                            visible: active
                            x: 8
                            width: parent.width - 8
                            sourceComponent: NameEdit {
                                path: meet.st.file
                                initial: meet.currentLabel
                            }
                        }

                        Item {
                            id: line1
                            visible: !head.renaming
                            width: parent.width
                            height: 28

                            // The title is the mode switch: Dictate <-> Meeting.
                            Rectangle {
                                id: titleBtn
                                width: titleRow.width + 16
                                height: parent.height
                                radius: height / 2
                                color: "transparent"

                                Row {
                                    id: titleRow
                                    x: 8
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 4

                                    StyledText {
                                        // Never wider than the space left, so a long title ends in "…".
                                        readonly property real room: line1.width - 16 - 20 - (otherDot.visible ? 12 : 0) - (timerText.visible ? timerText.implicitWidth : 0)
                                        width: Math.min(implicitWidth, Math.max(0, room))
                                        text: root.meeting ? "Meeting" : head.prob ? head.prob[1] : head.down ? "Service is off" : "Dictate"
                                        font.pixelSize: Theme.fontSizeLarge
                                        font.weight: Font.Medium
                                        color: head.bad || head.down ? Theme.error : Theme.surfaceText
                                        elide: Text.ElideRight
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    DIcon {
                                        name: "unfold_more"
                                        size: 16
                                        color: Theme.surfaceVariantText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    // A dot when the other mode is at work right now.
                                    Rectangle {
                                        id: otherDot
                                        visible: root.meeting ? (dict.recording || dict.busy) : meet.recording
                                        width: 8
                                        height: 8
                                        radius: 4
                                        color: root.meeting ? Theme.primary : root.recColor
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }

                                // Problems explain themselves on hover.
                                StateLayer {
                                    tooltipText: head.prob && head.prob[2] ? head.prob[2]
                                        : head.down ? "systemctl --user start dictate"
                                        : root.meeting ? "Switch to Dictate" : "Switch to Meeting"
                                    tooltipSide: "bottom"
                                    onClicked: root.setMode(root.meeting ? "dictate" : "meeting")
                                }
                            }

                            StyledText {
                                id: timerText
                                visible: root.meeting ? meet.recording : dict.recording
                                anchors.left: titleBtn.right
                                anchors.verticalCenter: titleBtn.verticalCenter
                                anchors.verticalCenterOffset: 1
                                text: root.meeting ? meet.elapsed : dict.elapsed
                                font.pixelSize: Theme.fontSizeMedium
                                font.features: { "tnum": 1 }
                                color: root.meeting ? root.recColor : Theme.primary
                            }
                        }

                        // Meeting being recorded: its name (click to rename) and size.
                        Item {
                            id: line2
                            visible: root.meeting && meet.recording && !head.renaming
                            x: 8
                            width: parent.width - 8
                            height: 16

                            Row {
                                id: nameRow
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 4

                                StyledText {
                                    width: Math.min(implicitWidth, Math.max(0, line2.width - 18 - sizeText.implicitWidth - 8))
                                    text: meet.currentLabel
                                    textFormat: Text.PlainText
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceText
                                    elide: Text.ElideRight
                                    wrapMode: Text.NoWrap
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                DIcon {
                                    name: "edit"
                                    size: 14
                                    color: nameMouse.containsMouse ? Theme.primary : Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                StyledText {
                                    id: sizeText
                                    text: "· " + root.fmtSize(meet.st.size)
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.features: { "tnum": 1 }
                                    color: Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            MouseArea {
                                id: nameMouse
                                anchors.fill: nameRow
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: meet.editingPath = meet.st.file
                            }
                        }
                    }

                    // Right side: the mode's buttons.
                    Item {
                        id: headRight
                        width: root.meeting ? recBtn.width : 36 + Theme.spacingS + 120
                        height: 36
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter

                        // Meeting: Record / Stop.
                        PillBtn {
                            id: recBtn
                            visible: root.meeting
                            anchors.right: parent.right
                            tint: meet.recording ? root.recColor : Theme.primary
                            onTint: meet.recording ? "white" : Theme.onPrimary
                            icon: meet.recording ? "stop" : "fiber_manual_record"
                            label: meet.recording ? "Stop" : "Record"
                            off: meet.busy
                            onClicked: meet.toggle()
                        }

                        // Dictate, live: an icon that stays put; locked while a take is going.
                        DActionButton {
                            visible: !root.meeting
                            anchors.left: parent.left
                            buttonSize: 36
                            // Always a circle (DMS makes 36 px buttons rounded squares).
                            radius: 18
                            iconSize: 18
                            iconName: "bolt"
                            iconFilled: true
                            // Stays enabled so the tooltip can explain why it is locked.
                            iconColor: dict.st.streaming ? Theme.primary : Theme.surfaceVariantText
                            backgroundColor: dict.st.streaming ? Theme.withAlpha(Theme.primary, 0.16) : "transparent"
                            opacity: head.locked ? 0.38 : 1
                            tooltipText: !dict.up ? "Service not running" : head.locked ? "Can't change while talking" : "Live transcription: " + (dict.st.streaming ? "on" : "off")
                            tooltipSide: "bottom"
                            onClicked: if (!head.locked) dict.run(["streaming", dict.st.streaming ? "off" : "on"])
                        }

                        // Dictate, fixed-width slot: Start / ✕ ✨ ✓ / Cancel / Retry.
                        // Same width in every state (3 × 36 + 2 × 6), so ⚡ never moves.
                        Item {
                            visible: !root.meeting
                            width: 120
                            height: 36
                            anchors.right: parent.right

                            PillBtn {
                                anchors.fill: parent
                                visible: !dict.recording && !dict.busy && !(dict.problem && dict.st.can_retry === true)
                                icon: "mic"
                                label: "Start"
                                off: !dict.up
                                onClicked: dict.run(["start"])
                            }
                            PillBtn {
                                anchors.fill: parent
                                visible: dict.problem && dict.st.can_retry === true
                                icon: "refresh"
                                label: "Retry"
                                onClicked: dict.run(["retry"])
                            }
                            PillBtn {
                                anchors.fill: parent
                                visible: dict.busy
                                ghost: true
                                icon: "close"
                                label: "Cancel"
                                onClicked: dict.run(["cancel"])
                            }
                            Row {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 6
                                visible: dict.recording

                                DActionButton {
                                    buttonSize: 36
                                    radius: 18
                                    iconSize: 18
                                    iconName: "close"
                                    iconColor: Theme.surfaceVariantText
                                    tooltipText: "Cancel"
                                    tooltipSide: "bottom"
                                    onClicked: dict.run(["cancel"])
                                }
                                DActionButton {
                                    buttonSize: 36
                                    radius: 18
                                    iconSize: 18
                                    iconName: "auto_awesome"
                                    iconFilled: true
                                    iconColor: Theme.surfaceVariantText
                                    tooltipText: "Clean up, then copy"
                                    tooltipSide: "bottom"
                                    onClicked: {
                                        dict.finishingHere = true;
                                        dict.run(["stop", "luna", "copy"]);
                                    }
                                }
                                // ✓: a plain filled circle (DActionButton morphs its shape on hover).
                                Rectangle {
                                    width: 36
                                    height: 36
                                    radius: 18
                                    color: doneArea.containsMouse ? Qt.lighter(Theme.primary, 1.1) : Theme.primary
                                    DIcon {
                                        anchors.centerIn: parent
                                        name: "check"
                                        size: 18
                                        filled: true
                                        color: Theme.onPrimary
                                    }
                                    MouseArea {
                                        id: doneArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            dict.finishingHere = true;
                                            dict.run(["stop", "direct", "copy"]);
                                        }
                                    }
                                    StateLayer {
                                        anchors.fill: parent
                                        stateColor: "transparent"
                                        tooltipText: "Done: copy"
                                        tooltipSide: "bottom"
                                        acceptedButtons: Qt.NoButton
                                    }
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    x: Theme.spacingS
                    width: parent.width - Theme.spacingS * 2
                    height: 1
                    color: Theme.withAlpha(Theme.outline, 0.2)
                }

                // Under the line: the mode's files.
                Loader {
                    width: parent.width
                    sourceComponent: root.meeting ? meetBody : dictBody
                }
            }

            // ---- Dictate: Recent ------------------------------------------------------

            Component {
                id: dictBody

                Column {
                    spacing: Theme.spacingS

                    // Recent header (or the delete-all question in the same spot).
                    Item {
                        x: Theme.spacingS
                        width: parent.width - Theme.spacingS * 2
                        height: 32

                        StyledText {
                            visible: !dict.confirmClear
                            text: "Recent"
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceVariantText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        ToastChip {
                            visible: !dict.confirmClear && opacity > 0
                        }

                        Row {
                            visible: !dict.confirmClear
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter

                            IconBtn {
                                iconName: "folder"
                                tip: "Open folder"
                                onClicked: {
                                    dict.run(["folder"]);
                                    root.closePopout();
                                }
                            }
                            IconBtn {
                                visible: dict.visibleTakes.length > 0
                                iconName: "delete_sweep"
                                tip: "Delete all (to trash)"
                                onClicked: {
                                    dict.confirmClear = true;
                                    confirmTimer.restart();
                                }
                            }
                        }

                        Timer {
                            id: confirmTimer
                            interval: 5000
                            onTriggered: dict.confirmClear = false
                        }

                        // Delete all? asks first, in the same row.
                        Item {
                            visible: dict.confirmClear
                            anchors.fill: parent

                            Row {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 8
                                DIcon {
                                    name: "delete_sweep"
                                    size: 18
                                    color: Theme.error
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                StyledText {
                                    text: "Delete all " + dict.visibleTakes.length + "?"
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                            Row {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 6
                                PillBtn {
                                    width: 80
                                    height: 28
                                    ghost: true
                                    label: "Cancel"
                                    onClicked: dict.confirmClear = false
                                }
                                Rectangle {
                                    width: 76
                                    height: 28
                                    radius: 14
                                    color: delArea.containsMouse ? Theme.withAlpha(Theme.error, 0.26) : Theme.withAlpha(Theme.error, 0.16)
                                    StyledText {
                                        anchors.centerIn: parent
                                        text: "Delete"
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                        color: Theme.error
                                    }
                                    MouseArea {
                                        id: delArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            dict.confirmClear = false;
                                            Proc.runCommand(null, [dict.bin, "trash", "all"], (out, code) => {
                                                root.showToast(code === 0 ? "All moved to trash" : "Delete failed");
                                                dict.showAll = false;
                                                dict.refreshList();
                                            }, 0, 20000, root);
                                        }
                                    }
                                }
                            }
                        }
                    }

                    StyledText {
                        visible: dict.visibleTakes.length === 0
                        x: Theme.spacingM
                        text: "Nothing yet"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    Flickable {
                        id: listFlick
                        visible: dict.visibleTakes.length > 0
                        x: Theme.spacingS
                        width: parent.width - Theme.spacingS * 2
                        height: Math.min(listCol.implicitHeight, 54 * (dict.showAll ? 7 : 5))
                        contentHeight: listCol.implicitHeight
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        interactive: contentHeight > height

                        Column {
                            id: listCol
                            width: listFlick.width

                            Repeater {
                                model: dict.showAll ? dict.visibleTakes : dict.visibleTakes.slice(0, 5)
                                delegate: TakeRow {
                                    required property var modelData
                                    take: modelData
                                }
                            }
                        }
                    }

                    Rectangle {
                        visible: dict.visibleTakes.length > 5
                        x: Theme.spacingS
                        width: parent.width - Theme.spacingS * 2
                        height: 34
                        radius: Theme.cornerRadius
                        color: moreArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.08) : "transparent"
                        StyledText {
                            anchors.centerIn: parent
                            text: dict.showAll ? "Show less" : "Show " + (dict.visibleTakes.length - 5) + " more"
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.primary
                        }
                        MouseArea {
                            id: moreArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: dict.showAll = !dict.showAll
                        }
                    }
                }
            }

            // ---- Meeting: Recordings ----------------------------------------------------

            Component {
                id: meetBody

                Column {
                    spacing: Theme.spacingS

                    Item {
                        x: Theme.spacingS
                        width: parent.width - Theme.spacingS * 2
                        height: 32

                        StyledText {
                            text: meet.recordings.length > 0 ? "Recordings · " + meet.recordings.length : "Recordings"
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceVariantText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        ToastChip {}

                        IconBtn {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            iconName: "folder"
                            tip: "Open folder"
                            onClicked: {
                                meet.run(["folder"]);
                                root.closePopout();
                            }
                        }
                    }

                    StyledText {
                        visible: meet.recordings.length === 0
                        x: Theme.spacingM
                        text: "Nothing yet"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    // All recordings; only the visible rows are built, so a long list stays fast.
                    ListView {
                        id: list
                        visible: count > 0
                        x: Theme.spacingS
                        width: parent.width - Theme.spacingS * 2
                        height: Math.min(count, 5) * 54
                        model: meet.recordings
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        interactive: contentHeight > height
                        reuseItems: true
                        onContentYChanged: meet.listY = contentY
                        onModelChanged: Qt.callLater(() => {
                            list.contentY = Math.max(0, Math.min(meet.keepY, list.contentHeight - list.height));
                        })

                        delegate: MeetRow {
                            required property var modelData
                            width: list.width
                            item: modelData
                        }
                    }
                }
            }
        }
    }
}

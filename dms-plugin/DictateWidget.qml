import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.DCommon.Widgets
import qs.Modules.Plugins

// One bar button for two things that can run at the same time:
//
//   Dictate   talk and the text is pasted              (the `dictate` daemon)
//   Record    record a meeting: mic + what you hear    (the `meetrec` script)
//
// Click the bar button for the popout, right click starts/stops dictating.
//
// Popout:
//   [● Record]                          [🎙 Dictate]    both idle
//   [■ 12:03]                     0:07 [✕] [✨] [✓]    both at work
//   -------------------------------------------------
//   [ Dictations | Meetings ]        (message) 📁 🗑    which files; opens on Dictations
//   the files
//
// Every message ("Copied", "Didn't go through") shows in one spot: the right
// end of the row with the switch. Nothing else moves.
PluginComponent {
    id: root

    layerNamespacePlugin: "dictate"

    // ---- popout state ------------------------------------------------------------------

    readonly property bool popoutOpen: interactionActive
    // Which files the list shows: "dictations" | "meetings". Nothing else depends on it.
    property string tab: "dictations"
    readonly property bool meetings: tab === "meetings"
    // Set right before opening, to open on Meetings instead of Dictations.
    property string openOn: ""

    function refreshTab() {
        if (root.meetings) {
            meet.refreshStatus();
            meet.refreshList();
            meet.refreshSize();
        } else {
            dict.refreshList();
        }
    }

    function showTab(t) {
        if (t === root.tab)
            return;
        root.tab = t;
        root.confirmClear = false;
        meet.editingPath = "";
        root.refreshTab();
    }

    // Tell the daemon: the card steps aside, and finishing copies instead of pasting.
    onPopoutOpenChanged: {
        dict.run(["popout", popoutOpen ? "on" : "off"]);
        root.confirmClear = false;
        if (popoutOpen) {
            root.tab = root.openOn !== "" ? root.openOn : "dictations";
            root.openOn = "";
            root.refreshTab();
        } else {
            // Closing drops a half-typed meeting name.
            meet.editingPath = "";
        }
    }

    // Open the popout on a list; if it is open on the other one, just switch.
    function openOnList(t) {
        if (root.popoutOpen) {
            if (root.tab !== t) {
                root.showTab(t);
                return;
            }
        } else {
            root.openOn = t;
        }
        root.triggerPopout();
    }

    pillRightClickAction: () => dict.run(["toggle"])

    // dms ipc call dictate popout   (e.g. for a keybind)
    IpcHandler {
        target: "dictate"

        function popout(): string {
            root.openOnList("dictations");
            return "ok";
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
            root.openOnList("meetings");
            return "ok";
        }

        // Jump straight to naming: the current meeting, or else the newest one.
        function rename(): string {
            const path = meet.recording ? meet.st.file : (meet.recordings.length > 0 ? meet.recordings[0].path : "");
            if (path === "")
                return "nothing to rename";
            if (root.popoutOpen) {
                root.showTab("meetings");
                meet.editingPath = path;
            } else {
                root.openOn = "meetings";
                meet.editingPath = path;
                root.triggerPopout();
            }
            return "ok";
        }
    }

    // ---- shared helpers ----------------------------------------------------------------

    property real nowMs: Date.now()
    // A short message after something you did ("Copied", "Delete failed").
    property string toast: ""
    property bool toastBad: false
    // "Delete all?" is being asked in the list header.
    property bool confirmClear: false
    // What the message spot says right now: [icon, text, more on hover, is it bad] or null.
    // Your last action first, else a dictation problem (those fade by themselves).
    readonly property var dictProb: dict.problem ? (dict.problemInfo[dict.st.problem] || dict.problemInfo.other) : null
    readonly property var note: toast !== "" ? [toastBad ? "error" : "check_circle", toast, "", toastBad]
        : dictProb ? [dictProb[0], dictProb[1], dictProb[2], true] : null
    // Kept while the message fades out.
    property var lastNote: ["check_circle", "", "", false]
    onNoteChanged: if (note) lastNote = note
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

    function showToast(text, bad) {
        root.toast = text;
        root.toastBad = bad === true;
        toastTimer.interval = root.toastBad ? 4000 : 1800;
        toastTimer.restart();
    }

    // After a command: say it worked, or say (in red) that it did not.
    function result(code, okText, failText) {
        root.showToast(code === 0 ? okText : failText, code !== 0);
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

        // [icon, what went wrong, what to do]
        readonly property var problemInfo: ({
            cleanfail: ["auto_awesome", "Clean-up failed", "Raw text used instead"],
            paste: ["content_paste", "Couldn't paste", "It's on your clipboard"],
            nospeech: ["voice_over_off", "No speech heard", ""],
            mic: ["mic_off", "Mic not working", "Check the input device"],
            eleven: ["cloud_off", "Didn't go through", "Audio is saved. Retry sends it again"],
            nokey: ["key_off", "No ElevenLabs key", "Run: dictate set-key"],
            other: ["error", "Something went wrong", ""]
        })

        property var takes: []
        property bool showAll: false
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
            if (root.popoutOpen && !root.meetings && dict.st.files !== dict._files)
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

        function clearAll() {
            Proc.runCommand(null, [dict.bin, "trash", "all"], (out, code) => {
                root.result(code, "All moved to trash", "Delete failed");
                dict.showAll = false;
                dict.refreshList();
            }, 0, 20000, root);
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
                root.result(code, okText, cmd === "clean" ? "Clean-up failed" : "Didn't go through");
                dict.refreshList();
            }, 0, 300000, root);
        }

        function copyTake(t, which) {
            Proc.runCommand(null, [dict.bin, "copy", t.stamp, which], (out, code) => {
                root.result(code, which === "clean" ? "Cleaned text copied" : "Copied", "Copy failed");
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
        property bool showAll: false
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
            const starting = !meet.recording;
            meet.run([starting ? "start" : "stop"], (out, code) => {
                meet.busy = false;
                if (code !== 0)
                    root.showToast(starting ? "Couldn't start recording" : "Couldn't stop recording", true);
                meet.refreshStatus();
                meet.refreshList();
            });
        }

        function clearAll() {
            meet.run(["delete", "all"], (out, code) => {
                root.result(code, "All moved to trash", "Delete failed");
                meet.showAll = false;
                meet.refreshList();
            });
        }

        function transcribe(item) {
            meet.run(["transcribe", item.path], (out, code) => {
                root.result(code, "Transcribing…", "No ElevenLabs key");
                meet.refreshList();
            });
        }

        function act(cmd, path, message) {
            meet.run([cmd, path], (out, code) => {
                if (message)
                    root.result(code, message, "That didn't work");
            });
        }

        function commitRename(path, name) {
            meet.editingPath = "";
            if (String(name).trim() === "")
                return;
            meet.run(["rename", path, name], (out, code) => {
                root.result(code, "Renamed", "Rename failed");
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
    //   idle        mic
    //   dictating   teal fill, mic + timer          (working: the mic breathes)
    //   meeting     red fill, ◉ + the meeting's timer
    //   both        red fill (the meeting matters more), ◉ 12:03  mic 0:07

    readonly property bool pillFilled: meet.recording || dict.recording || dict.busy

    // Plugins can't colour the pill itself, so this fills it from inside.
    component PillFill: Rectangle {
        property Item content
        readonly property Item box: content && content.parent ? content.parent.parent : null
        anchors.centerIn: parent
        visible: root.pillFilled
        width: box ? box.width : content.width + 16
        height: box ? box.height : root.widgetThickness
        radius: Theme.cornerRadius
        color: meet.recording ? root.recColor : Theme.withAlpha(Theme.primary, 0.16)
    }

    component PillRec: DIcon {
        name: "radio_button_checked"
        filled: true
        size: root.iconSize
        color: "white"
    }

    component PillMic: DIcon {
        name: dict.phase === "down" ? "mic_off"
            : dict.barError ? dict.problemIcon[dict.st.problem]
            : dict.phase === "cleaning" ? "auto_awesome" : "mic"
        filled: dict.active
        size: root.iconSize
        color: meet.recording ? "white"
            : dict.phase === "down" ? Theme.surfaceVariantText
            : dict.barError ? Theme.error
            : (dict.recording || dict.busy) ? Theme.primary
            : (Theme.widgetTextColor || Theme.surfaceText)
        opacity: pulse

        // Working (transcribing / cleaning up): the icon breathes.
        property real pulse: 1
        readonly property bool working: dict.busy
        onWorkingChanged: if (!working) pulse = 1
        SequentialAnimation on pulse {
            running: working
            loops: Animation.Infinite
            NumberAnimation { to: 0.35; duration: 600; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1; duration: 600; easing.type: Easing.InOutSine }
        }
    }

    component PillTime: StyledText {
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
                spacing: 8

                Row {
                    visible: meet.recording
                    spacing: 4
                    anchors.verticalCenter: parent.verticalCenter
                    PillRec {
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    PillTime {
                        text: meet.elapsed
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                // Next to a meeting the mic only shows while it has something to say.
                Row {
                    visible: !meet.recording || dict.active
                    spacing: 4
                    anchors.verticalCenter: parent.verticalCenter
                    PillMic {
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    PillTime {
                        visible: dict.recording
                        text: dict.elapsed
                        anchors.verticalCenter: parent.verticalCenter
                    }
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
                spacing: 2

                PillRec {
                    visible: meet.recording
                    anchors.horizontalCenter: parent.horizontalCenter
                }
                PillTime {
                    visible: meet.recording
                    text: meet.elapsed
                    font.pixelSize: Theme.fontSizeSmall - 2
                    anchors.horizontalCenter: parent.horizontalCenter
                }
                PillMic {
                    visible: !meet.recording || dict.active
                    anchors.horizontalCenter: parent.horizontalCenter
                }
                PillTime {
                    visible: dict.recording
                    text: dict.elapsed
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

    // A pill button: filled (Dictate, the red Stop), tonal (Record) or ghost (Cancel).
    component PillBtn: Rectangle {
        id: pb
        property string label
        property string icon: ""
        property color tint: Theme.primary
        property color onTint: Theme.onPrimary
        property bool tonal: false
        property bool ghost: false
        property bool off: false
        readonly property color fg: ghost ? Theme.surfaceVariantText : tonal ? Theme.surfaceText : onTint
        property color iconTint: fg
        readonly property bool hot: pbArea.containsMouse && !off
        signal clicked
        implicitHeight: 36
        implicitWidth: pbRow.implicitWidth + Theme.spacingL * 2
        radius: height / 2
        opacity: off ? 0.38 : 1
        color: ghost ? (hot ? Theme.withAlpha(Theme.surfaceText, 0.08) : "transparent")
            : tonal ? (hot ? Qt.lighter(Theme.surfaceContainerHigh, 1.2) : Theme.surfaceContainerHigh)
            : (hot ? Qt.lighter(tint, 1.1) : tint)
        Row {
            id: pbRow
            anchors.centerIn: parent
            spacing: 6
            DIcon {
                visible: pb.icon !== ""
                name: pb.icon
                size: 18
                filled: true
                color: pb.iconTint
                anchors.verticalCenter: parent.verticalCenter
            }
            StyledText {
                text: pb.label
                color: pb.fg
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                font.features: { "tnum": 1 }
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

    // One side of the Dictations | Meetings switch.
    component TabBtn: Rectangle {
        id: tb
        property string label
        property bool on: false
        // A dot: this side is at work right now.
        property bool busy: false
        property color busyColor: Theme.primary
        signal clicked
        width: tbRow.implicitWidth + 24
        height: 24
        radius: 12
        color: on ? Theme.withAlpha(Theme.primary, 0.18) : "transparent"
        Row {
            id: tbRow
            anchors.centerIn: parent
            spacing: 6
            StyledText {
                text: tb.label
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: tb.on ? Theme.primary : Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter
            }
            Rectangle {
                visible: tb.busy
                width: 6
                height: 6
                radius: 3
                color: tb.busyColor
                anchors.verticalCenter: parent.verticalCenter
            }
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: tb.clicked()
        }
    }

    // The row above the list: which files, the one spot for messages, Open folder,
    // Delete all ("Delete all?" asks first, in the same row).
    component ListHead: Item {
        id: lh
        property int count: 0
        signal openFolder
        signal clearAll

        x: Theme.spacingS
        width: parent ? parent.width - Theme.spacingS * 2 : 0
        height: 32

        Rectangle {
            id: tabs
            visible: !root.confirmClear
            width: tabRow.width + 4
            height: 28
            radius: 14
            color: Theme.surfaceContainerHigh
            anchors.verticalCenter: parent.verticalCenter

            Row {
                id: tabRow
                x: 2
                anchors.verticalCenter: parent.verticalCenter
                TabBtn {
                    label: "Dictations"
                    on: !root.meetings
                    busy: dict.recording || dict.busy
                    onClicked: root.showTab("dictations")
                }
                TabBtn {
                    label: "Meetings"
                    on: root.meetings
                    busy: meet.recording
                    busyColor: root.recColor
                    onClicked: root.showTab("meetings")
                }
            }
        }

        // The message: green for "it worked", red for a problem. It fades in and
        // out in place (the two buttons step aside), so nothing moves.
        Rectangle {
            id: chip
            readonly property var say: root.note || root.lastNote
            readonly property bool bad: say[3] === true
            readonly property color ink: bad ? Theme.error : Theme.success
            visible: !root.confirmClear && opacity > 0
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            // Never wider than the space next to the switch: a long text ends in "…".
            width: Math.min(chipRow.implicitWidth + Theme.spacingM * 2, lh.width - tabs.width - Theme.spacingS)
            height: 26
            radius: 13
            color: Theme.withAlpha(ink, 0.15)
            opacity: root.note ? 1 : 0
            Behavior on opacity {
                NumberAnimation { duration: 150 }
            }
            Row {
                id: chipRow
                x: Theme.spacingM
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6
                DIcon {
                    name: chip.say[0]
                    size: 16
                    color: chip.ink
                    anchors.verticalCenter: parent.verticalCenter
                }
                StyledText {
                    width: Math.min(implicitWidth, lh.width - tabs.width - Theme.spacingS - Theme.spacingM * 2 - 22)
                    text: chip.say[1]
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
            // What to do about it, on hover.
            StateLayer {
                stateColor: "transparent"
                acceptedButtons: Qt.NoButton
                cursorShape: Qt.ArrowCursor
                tooltipText: chip.say[2] !== "" ? chip.say[2] : null
                tooltipSide: "bottom"
            }
        }

        Row {
            visible: !root.confirmClear && root.note === null
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            IconBtn {
                iconName: "folder"
                tip: "Open folder"
                onClicked: lh.openFolder()
            }
            IconBtn {
                visible: lh.count > 0
                iconName: "delete_sweep"
                tip: "Delete all (to trash)"
                onClicked: {
                    root.confirmClear = true;
                    confirmTimer.restart();
                }
            }
        }

        Timer {
            id: confirmTimer
            interval: 5000
            onTriggered: root.confirmClear = false
        }

        Item {
            visible: root.confirmClear
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
                    text: "Delete all " + lh.count + (root.meetings ? " meetings?" : " dictations?")
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
                    onClicked: root.confirmClear = false
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
                            root.confirmClear = false;
                            lh.clearAll();
                        }
                    }
                }
            }
        }
    }

    // Under a list with more than 5 rows: "Show 13 more" / "Show less".
    component MoreBtn: Rectangle {
        id: mb
        property int count: 0
        property bool open: false
        signal toggled

        visible: count > 5
        x: Theme.spacingS
        width: parent ? parent.width - Theme.spacingS * 2 : 0
        height: 34
        radius: Theme.cornerRadius
        color: moreArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.08) : "transparent"
        StyledText {
            anchors.centerIn: parent
            text: mb.open ? "Show less" : "Show " + (mb.count - 5) + " more"
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.primary
        }
        MouseArea {
            id: moreArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: mb.toggled()
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
                    root.result(code, "Moved to trash", "Delete failed");
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
                text: meet.labelOf(rr.item)
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
                    text: meet.whenOf(rr.item) + " · " + root.clock(Number(rr.item.duration) * 1000) + " · " + root.fmtSize(rr.item.size) + (txState.text !== "" ? " · " : "")
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
                    root.result(code, "Moved to trash", "Delete failed");
                    meet.refreshList();
                })
            }
        }
    }

    // The meeting being recorded, on top of the Meetings list. Click to name it.
    component NowRow: Item {
        id: nr
        readonly property bool editing: meet.editingPath !== "" && meet.editingPath === meet.st.file

        x: Theme.spacingS
        width: parent ? parent.width - Theme.spacingS * 2 : 0
        height: 54

        HoverHandler {
            id: nowHover
        }

        Rectangle {
            anchors.fill: parent
            radius: Theme.cornerRadius
            color: Theme.surfaceText
            opacity: nowMouse.pressed ? 0.1 : nowHover.hovered ? 0.05 : 0
        }

        MouseArea {
            id: nowMouse
            anchors.fill: parent
            enabled: !nr.editing
            cursorShape: Qt.PointingHandCursor
            onClicked: meet.editingPath = meet.st.file
        }

        Rectangle {
            id: nowIcon
            x: Theme.spacingS
            width: 36
            height: 36
            radius: 18
            color: root.recColor
            anchors.verticalCenter: parent.verticalCenter

            DIcon {
                anchors.centerIn: parent
                name: "radio_button_checked"
                filled: true
                size: 18
                color: "white"
            }
        }

        Column {
            id: nowCol
            anchors.left: nowIcon.right
            anchors.leftMargin: Theme.spacingM
            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Loader {
                active: nr.editing
                visible: active
                width: parent.width
                sourceComponent: NameEdit {
                    path: meet.st.file
                    initial: meet.currentLabel
                }
            }

            Row {
                visible: !nr.editing
                spacing: 6

                StyledText {
                    width: Math.min(implicitWidth, nowCol.width - 22)
                    text: meet.currentLabel
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                    wrapMode: Text.NoWrap
                    anchors.verticalCenter: parent.verticalCenter
                }
                DIcon {
                    name: "edit"
                    size: 16
                    color: nowHover.hovered ? Theme.primary : Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            StyledText {
                visible: !nr.editing
                width: parent.width
                text: "Recording now · " + meet.elapsed + " · " + root.fmtSize(meet.st.size)
                font.pixelSize: Theme.fontSizeSmall
                font.features: { "tnum": 1 }
                color: Theme.error
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
            }
        }
    }

    // ---- popout --------------------------------------------------------------------------

    popoutContent: Component {
        PopoutComponent {
            id: popout

            // Only while you can see it: the size of the file being recorded.
            Timer {
                interval: 2000
                repeat: true
                running: root.popoutOpen && root.meetings && meet.recording
                onTriggered: meet.refreshSize()
            }

            Column {
                width: parent.width
                topPadding: Theme.spacingS
                bottomPadding: Theme.spacingS
                spacing: Theme.spacingS

                // The two controls. They don't depend on each other or on the list below.
                Item {
                    x: Theme.spacingS
                    width: parent.width - Theme.spacingS * 2
                    height: 40

                    // Left: record a meeting. While recording: stop + how long it has been.
                    PillBtn {
                        anchors.verticalCenter: parent.verticalCenter
                        tonal: !meet.recording
                        tint: root.recColor
                        onTint: "white"
                        iconTint: meet.recording ? "white" : Theme.error
                        icon: meet.recording ? "stop" : "fiber_manual_record"
                        label: meet.recording ? meet.elapsed : "Record"
                        off: meet.busy
                        onClicked: {
                            // Show the meetings, so the new one is right there to name.
                            root.showTab("meetings");
                            meet.toggle();
                        }
                    }

                    // Right: dictate. While talking: timer + ✕ ✨ ✓.
                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6

                        StyledText {
                            visible: dict.recording
                            rightPadding: 4
                            text: dict.elapsed
                            font.pixelSize: Theme.fontSizeMedium
                            font.features: { "tnum": 1 }
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        // Idle: Dictate. After a failed upload: Retry. Daemon gone: off.
                        PillBtn {
                            readonly property bool retry: dict.problem && dict.st.can_retry === true
                            visible: !dict.recording && !dict.busy
                            icon: !dict.up ? "mic_off" : retry ? "refresh" : "mic"
                            label: !dict.up ? "Service off" : retry ? "Retry" : "Dictate"
                            off: !dict.up
                            onClicked: dict.run([retry ? "retry" : "start"])
                        }

                        // Working (transcribing / cleaning up).
                        DSpinner {
                            visible: dict.busy
                            width: 22
                            height: 22
                            size: 22
                            strokeWidth: 2
                            color: Theme.primary
                            running: dict.busy && root.popoutOpen
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        PillBtn {
                            visible: dict.busy
                            ghost: true
                            icon: "close"
                            label: "Cancel"
                            onClicked: dict.run(["cancel"])
                        }

                        // Talking: ✕ ✨ ✓.
                        DActionButton {
                            visible: dict.recording
                            buttonSize: 36
                            // Always a circle (DMS makes 36 px buttons rounded squares).
                            radius: 18
                            iconSize: 18
                            iconName: "close"
                            iconColor: Theme.surfaceVariantText
                            tooltipText: "Cancel"
                            tooltipSide: "bottom"
                            onClicked: dict.run(["cancel"])
                        }
                        DActionButton {
                            visible: dict.recording
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
                            visible: dict.recording
                            width: 36
                            height: 36
                            radius: 18
                            color: doneArea.containsMouse ? Qt.lighter(Theme.primary, 1.1) : Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
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

                Rectangle {
                    x: Theme.spacingS
                    width: parent.width - Theme.spacingS * 2
                    height: 1
                    color: Theme.withAlpha(Theme.outline, 0.2)
                }

                // Which files, messages, Open folder, Delete all.
                ListHead {
                    count: root.meetings ? meet.recordings.length : dict.visibleTakes.length
                    onOpenFolder: {
                        if (root.meetings)
                            meet.run(["folder"]);
                        else
                            dict.run(["folder"]);
                        root.closePopout();
                    }
                    onClearAll: root.meetings ? meet.clearAll() : dict.clearAll()
                }

                Loader {
                    width: parent.width
                    sourceComponent: root.meetings ? meetBody : dictBody
                }
            }

            // ---- Dictations ---------------------------------------------------------------

            Component {
                id: dictBody

                Column {
                    spacing: Theme.spacingS

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

                    MoreBtn {
                        count: dict.visibleTakes.length
                        open: dict.showAll
                        onToggled: dict.showAll = !dict.showAll
                    }
                }
            }

            // ---- Meetings -----------------------------------------------------------------

            Component {
                id: meetBody

                Column {
                    spacing: Theme.spacingS

                    // The one being recorded right now comes first.
                    NowRow {
                        visible: meet.recording
                    }

                    StyledText {
                        visible: meet.recordings.length === 0 && !meet.recording
                        x: Theme.spacingM
                        text: "Nothing yet"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    // The newest 5, or all of them (only the visible rows are built,
                    // so a long list stays fast).
                    ListView {
                        id: list
                        visible: count > 0
                        x: Theme.spacingS
                        width: parent.width - Theme.spacingS * 2
                        height: Math.min(count, meet.showAll ? 7 : 5) * 54
                        model: meet.showAll ? meet.recordings : meet.recordings.slice(0, 5)
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

                    MoreBtn {
                        count: meet.recordings.length
                        open: meet.showAll
                        onToggled: meet.showAll = !meet.showAll
                    }
                }
            }
        }
    }
}

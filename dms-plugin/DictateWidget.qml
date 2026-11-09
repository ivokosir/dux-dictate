import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.DCommon.Widgets
import qs.Modules.Plugins

// Bar mic: click opens the popout, right click starts/stops right away.
//
// Popout: one header row that never moves
//   [mic] Dictate 0:12 ............ [⚡] [ Start | ✨ ✓ | Cancel | Retry ]
// and Recent, which is just the files in ~/Music/Dictations.
PluginComponent {
    id: root

    layerNamespacePlugin: "dictate"

    property string bin: Quickshell.env("HOME") + "/.local/bin/dictate"
    property var st: ({ daemon: false })
    property real nowMs: Date.now()

    readonly property bool up: st.daemon === true
    readonly property string phase: up ? (st.state || "idle") : "down"
    readonly property bool recording: phase === "recording"
    readonly property bool busy: phase === "transcribing" || phase === "cleaning"
    readonly property bool problem: phase === "problem"
    readonly property bool popoutOpen: interactionActive

    function run(args) {
        Quickshell.execDetached([root.bin].concat(args));
    }

    function clock(ms) {
        const s = Math.max(0, Math.floor(ms / 1000));
        const h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, x = s % 60;
        const pad = n => String(n).padStart(2, "0");
        return (h > 0 ? h + ":" + pad(m) : m) + ":" + pad(x);
    }

    Process {
        id: watcher
        command: [root.bin, "watch"]
        running: true
        stdout: SplitParser {
            onRead: data => {
                // Mic level lines ("L 0.42") are only for the card.
                if (data.charCodeAt(0) === 76)
                    return;
                try {
                    root.st = JSON.parse(data);
                } catch (e) {}
            }
        }
        onExited: {
            root.st = { daemon: false };
            restartWatcher.start();
        }
    }

    Timer {
        id: restartWatcher
        interval: 2000
        onTriggered: watcher.running = true
    }

    // The timer only ticks while someone can see it (the popout).
    Timer {
        interval: 500
        repeat: true
        running: root.recording && root.popoutOpen
        triggeredOnStart: true
        onTriggered: root.nowMs = Date.now()
    }

    // Tell the daemon: the card steps aside, and finishing copies instead of pasting.
    onPopoutOpenChanged: {
        root.run(["popout", popoutOpen ? "on" : "off"]);
        if (popoutOpen) {
            root.confirmClear = false;
            root.refreshList();
        }
    }

    pillRightClickAction: () => root.run(["toggle"])

    // dms ipc call dictate popout   (e.g. for a keybind)
    IpcHandler {
        target: "dictate"
        function popout(): string {
            root.triggerPopout();
            return "ok";
        }
    }

    // ---- Recent: just the files ------------------------------------------------

    property var takes: []
    property bool showAll: false
    property bool confirmClear: false
    // stamp -> "transcribe" | "clean" while a row is working
    property var rowBusy: ({})
    property string toast: ""
    property string lastToast: ""
    // ✨/✓ pressed in the popout: say "Copied" when it is done.
    property bool finishingHere: false

    readonly property var visibleTakes: takes.filter(t => t.stamp !== st.current)

    function refreshList() {
        Proc.runCommand(null, [root.bin, "list", "20"], (out, code) => {
            try {
                root.takes = JSON.parse(out.trim());
            } catch (e) {}
        }, 0, 10000, root);
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

    Connections {
        target: root
        function onStChanged() {
            if (root.popoutOpen && root.st.files !== root._files)
                root.refreshList();
            root._files = root.st.files;
            if (root.finishingHere && root.phase === "idle") {
                root.finishingHere = false;
                root.showToast("Copied");
            } else if (root.finishingHere && root.phase === "problem") {
                root.finishingHere = false;
            }
        }
    }
    property var _files: -1

    function setBusy(stamp, what) {
        const b = Object.assign({}, root.rowBusy);
        if (what)
            b[stamp] = what;
        else
            delete b[stamp];
        root.rowBusy = b;
    }

    function rowAction(stamp, cmd, okText) {
        root.setBusy(stamp, cmd);
        Proc.runCommand(null, [root.bin, cmd, stamp], (out, code) => {
            root.setBusy(stamp, "");
            root.showToast(code === 0 ? okText : "Failed");
            root.refreshList();
        }, 0, 300000, root);
    }

    function copyTake(t, which) {
        Proc.runCommand(null, [root.bin, "copy", t.stamp, which], (out, code) => {
            root.showToast(code !== 0 ? "Failed" : which === "clean" ? "Cleaned text copied" : "Copied");
        }, 0, 10000, root);
    }

    // "2026-11-09_14-31-02" -> "Today 14:31" / "Yesterday 18:20" / "8 Nov 09:12"
    function whenOf(stamp) {
        const m = String(stamp).match(/^(\d{4})-(\d\d)-(\d\d)_(\d\d)-(\d\d)/);
        if (!m)
            return stamp;
        const d = new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]);
        const now = new Date();
        const hm = m[4] + ":" + m[5];
        if (d.toDateString() === now.toDateString())
            return "Today " + hm;
        const y = new Date(now);
        y.setDate(now.getDate() - 1);
        if (d.toDateString() === y.toDateString())
            return "Yesterday " + hm;
        return Qt.formatDate(d, "d MMM") + " " + hm;
    }

    // ---- bar pill ------------------------------------------------------------------

    readonly property var problemIcon: ({ mic: "mic_off", eleven: "cloud_off", nokey: "key_off" })
    readonly property bool barError: problem && !!problemIcon[st.problem]
    readonly property color pillColor: phase === "down" ? Theme.surfaceVariantText
        : barError ? Theme.error
        : (recording || busy) ? Theme.primary
        : (Theme.widgetTextColor || Theme.surfaceText)

    // A soft teal fill behind the mic while talking (plugins can't color the pill itself).
    component TalkFill: Rectangle {
        property Item content
        readonly property Item box: content && content.parent ? content.parent.parent : null
        anchors.centerIn: parent
        visible: root.recording
        width: box ? box.width : content.width + 16
        height: box ? box.height : root.widgetThickness
        radius: Theme.cornerRadius
        color: Theme.withAlpha(Theme.primary, 0.16)
    }

    component PillIcon: DIcon {
        name: root.phase === "down" ? "mic_off" : root.barError ? root.problemIcon[root.st.problem] : "mic"
        filled: root.recording || root.busy || root.barError
        size: root.iconSize
        color: root.pillColor
        opacity: root.busy ? 0.55 : 1
    }

    horizontalBarPill: Component {
        Item {
            id: hp
            implicitWidth: hIcon.implicitWidth
            implicitHeight: hIcon.implicitHeight
            TalkFill {
                content: hp
            }
            PillIcon {
                id: hIcon
                anchors.centerIn: parent
            }
        }
    }

    verticalBarPill: Component {
        Item {
            id: vp
            implicitWidth: vIcon.implicitWidth
            implicitHeight: vIcon.implicitHeight
            TalkFill {
                content: vp
            }
            PillIcon {
                id: vIcon
                anchors.centerIn: parent
            }
        }
    }

    // ---- popout building blocks ------------------------------------------------------

    component IconBtn: DActionButton {
        property string tip: ""
        iconSize: 18
        iconColor: Theme.surfaceVariantText
        buttonSize: 32
        tooltipText: tip !== "" ? tip : null
        tooltipSide: "top"
    }

    // Filled pill button (Start, Retry) or ghost (Cancel).
    component PillBtn: Rectangle {
        id: pb
        property string label
        property string icon
        property bool ghost: false
        property bool off: false
        signal clicked
        height: 36
        radius: 18
        opacity: off ? 0.38 : 1
        color: ghost ? (pbArea.containsMouse && !off ? Theme.withAlpha(Theme.surfaceText, 0.08) : "transparent")
                     : (pbArea.containsMouse && !off ? Qt.lighter(Theme.primary, 1.1) : Theme.primary)
        readonly property color fg: ghost ? Theme.surfaceVariantText : Theme.onPrimary
        Row {
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

    // [icon, title, hint]
    readonly property var problemInfo: ({
        cleanfail: ["auto_awesome", "Clean-up failed", "Raw text used instead"],
        paste: ["content_paste", "Couldn't paste", "It's on your clipboard"],
        nospeech: ["voice_over_off", "No speech heard", ""],
        mic: ["mic_off", "Mic not working", "Check the input device"],
        eleven: ["cloud_off", "Didn't go through", "Audio is saved. Retry sends it again"],
        nokey: ["key_off", "No ElevenLabs key", "Run: dictate set-key"],
        other: ["error", "Something went wrong", ""]
    })

    component TakeRow: Item {
        id: tr
        property var take
        readonly property bool hovered: rowHover.hovered
        readonly property string work: root.rowBusy[take.stamp] || ""
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
            onClicked: root.copyTake(tr.take, tr.take.cleaned ? "clean" : "raw")
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
                text: root.whenOf(tr.take.stamp) + " · " + root.clock(tr.take.secs * 1000)
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
                onClicked: root.rowAction(tr.take.stamp, "transcribe", "Transcribed")
            }
            IconBtn {
                visible: !tr.audioOnly
                iconName: "auto_awesome"
                tip: tr.take.cleaned ? "Copy cleaned text" : "Clean up"
                onClicked: tr.take.cleaned ? root.copyTake(tr.take, "clean") : root.rowAction(tr.take.stamp, "clean", "Cleaned up")
            }
            IconBtn {
                visible: !tr.audioOnly
                iconName: "content_copy"
                tip: "Copy raw text"
                onClicked: root.copyTake(tr.take, "raw")
            }
            IconBtn {
                iconName: "folder_open"
                tip: "Show in folder"
                onClicked: {
                    root.run(["reveal", tr.take.stamp]);
                    root.closePopout();
                }
            }
            IconBtn {
                iconName: "delete"
                tip: "Delete (to trash)"
                onClicked: Proc.runCommand(null, [root.bin, "trash", tr.take.stamp], (out, code) => {
                    root.showToast(code === 0 ? "Moved to trash" : "Delete failed");
                    root.refreshList();
                }, 0, 10000, root)
            }
        }
    }

    // ---- popout --------------------------------------------------------------------------

    popoutWidth: 400

    popoutContent: Component {
        PopoutComponent {
            id: popout

            Column {
                width: parent.width
                topPadding: Theme.spacingS
                bottomPadding: Theme.spacingS
                spacing: Theme.spacingS

                // Header: the same row in every state. Only the title and the slot change.
                Item {
                    id: head
                    readonly property var prob: root.problem ? (root.problemInfo[root.st.problem] || root.problemInfo.other) : null
                    readonly property bool locked: root.recording || root.busy || !root.up

                    x: Theme.spacingS
                    width: parent.width - Theme.spacingS * 2
                    height: 44

                    Rectangle {
                        id: headIcon
                        width: 40
                        height: 40
                        radius: 20
                        anchors.verticalCenter: parent.verticalCenter
                        color: head.prob ? Theme.withAlpha(Theme.error, 0.14)
                            : (root.recording || root.busy) ? Theme.withAlpha(Theme.primary, 0.16)
                            : Theme.surfaceContainerHigh

                        DSpinner {
                            anchors.fill: parent
                            size: 40
                            strokeWidth: 2
                            color: Theme.primary
                            visible: root.busy
                            running: root.busy && root.popoutOpen
                        }
                        DIcon {
                            anchors.centerIn: parent
                            name: head.prob ? head.prob[0] : root.phase === "down" ? "mic_off" : root.phase === "cleaning" ? "auto_awesome" : "mic"
                            filled: true
                            size: 22
                            color: head.prob ? Theme.error : (root.recording || root.busy) ? Theme.primary : Theme.surfaceVariantText
                        }
                    }

                    Row {
                        anchors.left: headIcon.right
                        anchors.leftMargin: Theme.spacingM
                        anchors.right: liveBtn.left
                        anchors.rightMargin: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 8
                        clip: true

                        StyledText {
                            id: titleText
                            text: head.prob ? head.prob[1] : root.phase === "down" ? "Service not running" : "Dictate"
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.Medium
                            color: head.prob || root.phase === "down" ? Theme.error : Theme.surfaceText
                            elide: Text.ElideRight
                            anchors.verticalCenter: parent.verticalCenter

                            // Problems explain themselves on hover.
                            StateLayer {
                                anchors.fill: parent
                                stateColor: "transparent"
                                tooltipText: head.prob && head.prob[2] ? head.prob[2] : root.phase === "down" ? "systemctl --user start dictate" : null
                                tooltipSide: "bottom"
                            }
                        }

                        StyledText {
                            visible: root.recording
                            text: root.clock(root.nowMs - (Number(root.st.started_ms) || root.nowMs))
                            font.pixelSize: Theme.fontSizeMedium
                            font.features: { "tnum": 1 }
                            color: Theme.primary
                            anchors.baseline: titleText.baseline
                        }
                    }

                    // Live: an icon that stays put; locked while a take is going.
                    DActionButton {
                        id: liveBtn
                        anchors.right: slot.left
                        anchors.rightMargin: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        buttonSize: 36
                        iconSize: 18
                        iconName: "bolt"
                        iconFilled: true
                        // Stays enabled so the tooltip can explain why it is locked.
                        iconColor: root.st.streaming ? Theme.primary : Theme.surfaceVariantText
                        backgroundColor: root.st.streaming ? Theme.withAlpha(Theme.primary, 0.16) : "transparent"
                        opacity: head.locked ? 0.38 : 1
                        tooltipText: !root.up ? "Service not running" : head.locked ? "Can't change while talking" : "Live transcription: " + (root.st.streaming ? "on" : "off")
                        tooltipSide: "bottom"
                        onClicked: if (!head.locked) root.run(["streaming", root.st.streaming ? "off" : "on"])
                    }

                    // Fixed-width slot on the right: Start / ✨ ✓ / Cancel / Retry.
                    Item {
                        id: slot
                        width: 92
                        height: 36
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter

                        PillBtn {
                            anchors.fill: parent
                            visible: !root.recording && !root.busy && !(root.problem && root.st.can_retry === true)
                            icon: "mic"
                            label: "Start"
                            off: !root.up
                            onClicked: root.run(["start"])
                        }
                        PillBtn {
                            anchors.fill: parent
                            visible: root.problem && root.st.can_retry === true
                            icon: "refresh"
                            label: "Retry"
                            onClicked: root.run(["retry"])
                        }
                        PillBtn {
                            anchors.fill: parent
                            visible: root.busy
                            ghost: true
                            icon: "close"
                            label: "Cancel"
                            onClicked: root.run(["cancel"])
                        }
                        Row {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 6
                            visible: root.recording

                            DActionButton {
                                buttonSize: 36
                                iconSize: 18
                                iconName: "auto_awesome"
                                iconFilled: true
                                iconColor: Theme.surfaceVariantText
                                tooltipText: "Clean up, then copy"
                                tooltipSide: "bottom"
                                onClicked: {
                                    root.finishingHere = true;
                                    root.run(["stop", "luna", "copy"]);
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
                                        root.finishingHere = true;
                                        root.run(["stop", "direct", "copy"]);
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

                Rectangle {
                    x: Theme.spacingS
                    width: parent.width - Theme.spacingS * 2
                    height: 1
                    color: Theme.withAlpha(Theme.outline, 0.2)
                }

                // Recent header (or the delete-all question in the same spot).
                Item {
                    x: Theme.spacingS
                    width: parent.width - Theme.spacingS * 2
                    height: 32

                    Row {
                        visible: !root.confirmClear
                        anchors.fill: parent

                        StyledText {
                            text: "Recent"
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceVariantText
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    // "Copied", "Moved to trash": fades in place, nothing moves.
                    Rectangle {
                        visible: !root.confirmClear && opacity > 0
                        anchors.centerIn: parent
                        width: toastRow.implicitWidth + Theme.spacingL * 2
                        height: 26
                        radius: 13
                        color: Theme.withAlpha(Theme.success, 0.15)
                        opacity: root.toast !== "" ? 1 : 0
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
                                text: root.toast !== "" ? root.toast : root.lastToast
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                    }

                    Row {
                        visible: !root.confirmClear
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter

                        IconBtn {
                            iconName: "folder"
                            tip: "Open folder"
                            onClicked: {
                                root.run(["folder"]);
                                root.closePopout();
                            }
                        }
                        IconBtn {
                            visible: root.visibleTakes.length > 0
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

                    // Delete all? asks first, in the same row.
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
                                text: "Delete all " + root.visibleTakes.length + "?"
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
                                icon: ""
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
                                        Proc.runCommand(null, [root.bin, "trash", "all"], (out, code) => {
                                            root.showToast(code === 0 ? "All moved to trash" : "Delete failed");
                                            root.showAll = false;
                                            root.refreshList();
                                        }, 0, 20000, root);
                                    }
                                }
                            }
                        }
                    }
                }

                StyledText {
                    visible: root.visibleTakes.length === 0
                    x: Theme.spacingM
                    text: "Nothing yet"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                Flickable {
                    id: listFlick
                    visible: root.visibleTakes.length > 0
                    x: Theme.spacingS
                    width: parent.width - Theme.spacingS * 2
                    height: Math.min(listCol.implicitHeight, 54 * (root.showAll ? 7 : 5))
                    contentHeight: listCol.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    interactive: contentHeight > height

                    Column {
                        id: listCol
                        width: listFlick.width

                        Repeater {
                            model: root.showAll ? root.visibleTakes : root.visibleTakes.slice(0, 5)
                            delegate: TakeRow {
                                required property var modelData
                                take: modelData
                            }
                        }
                    }
                }

                Rectangle {
                    visible: root.visibleTakes.length > 5
                    x: Theme.spacingS
                    width: parent.width - Theme.spacingS * 2
                    height: 34
                    radius: Theme.cornerRadius
                    color: moreArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.08) : "transparent"
                    StyledText {
                        anchors.centerIn: parent
                        text: root.showAll ? "Show less" : "Show " + (root.visibleTakes.length - 5) + " more"
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Medium
                        color: Theme.primary
                    }
                    MouseArea {
                        id: moreArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.showAll = !root.showAll
                    }
                }
            }
        }
    }
}

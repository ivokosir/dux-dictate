import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.DCommon.Widgets
import qs.Modules.Plugins

// Runs once (daemon surface): the small pill in the top-right corner.
//
//   talking        [mic glow] 0:12        mouse on it: [✕] [✨] [✓]
//   working        [mic + spinner] [✕]
//   problem        [icon] text [⟳] [✕]
//
// It hides while the bar popout is open (the popout shows the same things),
// and disappears when a take is done.
PluginComponent {
    id: root

    property var popoutService: null
    property string bin: Quickshell.env("HOME") + "/.local/bin/dictate"
    property var st: ({ daemon: false })
    property real nowMs: Date.now()
    // Mic loudness 0..1 while recording; the mic circle glows with it.
    property real voice: 0

    readonly property string phase: st.daemon === true ? (st.state || "idle") : "idle"
    readonly property bool recording: phase === "recording"
    readonly property bool busy: phase === "transcribing" || phase === "cleaning"
    readonly property bool problem: phase === "problem"
    // Not every message is bad news: "cleaned text copied" is just information.
    readonly property bool notice: problem && st.problem === "cleancopied"
    readonly property bool bad: problem && !notice
    readonly property bool shown: (recording || busy || problem) && st.popout !== true

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
                // "L 0.420" = mic level (~20x/s while recording): cheap path, no JSON.
                if (data.charCodeAt(0) === 76) {
                    const v = root.recording && root.shown ? (Number(data.slice(2)) || 0) : 0;
                    // Ignore tiny changes so silence doesn't cause redraws.
                    if (Math.abs(v - root.voice) > 0.04 || (v === 0 && root.voice !== 0))
                        root.voice = v;
                    return;
                }
                let next;
                try {
                    next = JSON.parse(data);
                } catch (e) {
                    return;
                }
                if (next.state !== "recording")
                    root.voice = 0;
                root.st = next;
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

    Timer {
        interval: 500
        repeat: true
        running: root.recording && root.shown
        triggeredOnStart: true
        onTriggered: root.nowMs = Date.now()
    }

    readonly property var targetScreen: {
        const name = NiriService.currentOutput;
        for (const s of Quickshell.screens) {
            if (s.name === name)
                return s;
        }
        return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null;
    }

    // [icon, text, small text after it]
    readonly property var problemInfo: ({
        cleanfail: ["auto_awesome", "Clean-up failed", "pasted raw"],
        paste: ["content_paste", "Couldn't paste", "on clipboard"],
        nospeech: ["voice_over_off", "No speech heard", ""],
        mic: ["mic_off", "Mic not working", ""],
        eleven: ["cloud_off", "Didn't go through", ""],
        livefail: ["cloud_off", "Live stopped", "full text copied"],
        cleancopied: ["auto_awesome", "Cleaned & copied", ""],
        nokey: ["key_off", "No API key", ""],
        other: ["error", "Something failed", ""]
    })
    readonly property var prob: problemInfo[st.problem] || problemInfo.other

    // ---- building blocks: all 32 px circles, 6 px apart ------------------------

    readonly property int unit: 32
    readonly property int gap: 6

    // A round icon button: ghost (default) or filled.
    component RoundBtn: Rectangle {
        id: rb
        property string icon
        property bool filled: false
        property color hoverTint: Theme.surfaceText
        signal clicked
        width: root.unit
        height: root.unit
        radius: width / 2
        color: filled ? (area.containsMouse ? Qt.lighter(Theme.primary, 1.12) : Theme.primary)
                      : (area.containsMouse ? Theme.withAlpha(hoverTint, 0.1) : "transparent")
        DIcon {
            anchors.centerIn: parent
            name: rb.icon
            size: 18
            filled: true
            color: rb.filled ? Theme.onPrimary : (area.containsMouse && rb.hoverTint !== Theme.surfaceText ? rb.hoverTint : Theme.surfaceVariantText)
        }
        MouseArea {
            id: area
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: rb.clicked()
        }
    }

    // One piece of the morph: spins and shrinks away, or back in.
    component Morph: Item {
        property bool on: true
        property int turn: 90
        opacity: on ? 1 : 0
        scale: on ? 1 : 0.5
        rotation: on ? 0 : turn
        Behavior on opacity {
            NumberAnimation { duration: 200 }
        }
        Behavior on scale {
            NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
        }
        Behavior on rotation {
            NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
        }
    }

    // ---- the pill ----------------------------------------------------------------

    PanelWindow {
        id: win

        readonly property real pad: 16
        // Fixed size: the pill grows inside it, so the window never resizes.
        readonly property real maxWidth: 360

        screen: root.targetScreen
        visible: root.shown || card.opacity > 0.01
        color: "transparent"

        WlrLayershell.namespace: "dms:dictate"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.exclusiveZone: -1
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors.top: true
        anchors.right: true

        readonly property real topGap: {
            if (!screen)
                return Theme.popupDistance;
            const info = SettingsData.getAdjacentBarInfo(screen, SettingsData.notificationPopupPosition, {
                id: "dictate",
                screenPreferences: [screen.name],
                autoHide: false
            }, true);
            return info && info.topBar > 0 ? info.topBar : Theme.popupDistance;
        }

        // A little below the bar, so the pill clears the window borders under it.
        readonly property real drop: 12

        margins {
            top: Math.max(0, topGap + drop - pad)
            right: Math.max(0, Theme.popupDistance - pad)
        }

        implicitWidth: maxWidth + pad * 2
        implicitHeight: 44 + pad * 2

        mask: Region {
            item: card
        }

        ElevationShadow {
            anchors.fill: card
            level: Theme.elevationLevel3
            targetRadius: card.radius
            targetColor: card.color
            opacity: card.opacity
            shadowEnabled: Theme.elevationEnabled
        }

        Rectangle {
            id: card

            readonly property bool hovered: hover.hovered && root.recording
            // Which row decides the width right now.
            readonly property Item row: root.recording ? (hovered ? acts : rest) : info

            height: 44
            width: Math.ceil(row.implicitWidth) + root.gap * 2 + 2
            x: win.width - win.pad - width
            y: win.pad + (root.shown ? 0 : -10)
            radius: height / 2
            color: Theme.hostSurface
            border.width: 1
            border.color: root.bad ? Theme.withAlpha(Theme.error, 0.3) : Theme.withAlpha(Theme.outlineVariant, 0.55)
            opacity: root.shown ? 1 : 0
            clip: true

            Behavior on width {
                // Ease out only: the pill moves straight to its new size, no overshoot.
                NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
            }
            Behavior on opacity {
                NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
            }
            Behavior on y {
                NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
            }

            HoverHandler {
                id: hover
            }

            // At rest while talking: glowing mic + timer.
            Row {
                id: rest
                x: root.gap + 1
                anchors.verticalCenter: parent.verticalCenter
                spacing: root.gap
                visible: root.recording
                enabled: !card.hovered

                Morph {
                    on: !card.hovered
                    width: root.unit
                    height: root.unit

                    Rectangle {
                        anchors.fill: parent
                        radius: width / 2
                        color: Theme.withAlpha(Theme.primary, 0.12 + root.voice * 0.28)
                        scale: 1 + root.voice * 0.1
                        Behavior on color {
                            ColorAnimation { duration: 160 }
                        }
                        Behavior on scale {
                            NumberAnimation { duration: 160; easing.type: Easing.OutQuad }
                        }
                    }
                    DIcon {
                        anchors.centerIn: parent
                        name: "mic"
                        filled: true
                        size: 18
                        color: Theme.primary
                    }
                }

                // Text has no circle around it: 7 px more after the timer so it ends
                // as far from the edge as an icon glyph does (6 + 1 + 7 = 14 px).
                Morph {
                    on: !card.hovered
                    width: timerText.implicitWidth + 7
                    height: root.unit
                    StyledText {
                        id: timerText
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.clock(root.nowMs - (Number(root.st.started_ms) || root.nowMs))
                        font.pixelSize: Theme.fontSizeSmall
                        font.features: { "tnum": 1 }
                        color: Theme.surfaceVariantText
                    }
                }
            }

            // Mouse on it while talking: ✕ ✨ ✓ in the same spots.
            Row {
                id: acts
                x: root.gap + 1
                anchors.verticalCenter: parent.verticalCenter
                spacing: root.gap
                visible: root.recording
                enabled: card.hovered

                Morph {
                    on: card.hovered
                    turn: -90
                    width: root.unit
                    height: root.unit
                    RoundBtn {
                        icon: "close"
                        onClicked: root.run(["cancel"])
                    }
                }
                Morph {
                    on: card.hovered
                    turn: -90
                    width: root.unit
                    height: root.unit
                    RoundBtn {
                        icon: "auto_awesome"
                        hoverTint: Theme.primary
                        onClicked: root.run(["stop", "luna"])
                    }
                }
                Morph {
                    on: card.hovered
                    turn: -90
                    width: root.unit
                    height: root.unit
                    RoundBtn {
                        icon: "check"
                        filled: true
                        onClicked: root.run(["stop", "direct"])
                    }
                }
            }

            // Working or a problem.
            Row {
                id: info
                x: root.gap + 1
                anchors.verticalCenter: parent.verticalCenter
                spacing: root.gap
                visible: !root.recording

                Item {
                    width: root.unit
                    height: root.unit

                    Rectangle {
                        anchors.fill: parent
                        radius: width / 2
                        color: root.bad ? Theme.withAlpha(Theme.error, 0.14) : Theme.withAlpha(Theme.primary, 0.14)
                    }
                    DSpinner {
                        anchors.fill: parent
                        size: root.unit
                        strokeWidth: 2
                        color: Theme.primary
                        visible: root.busy
                        running: root.busy && root.shown
                    }
                    DIcon {
                        anchors.centerIn: parent
                        name: root.problem ? root.prob[0] : root.phase === "cleaning" ? "auto_awesome" : "mic"
                        filled: true
                        size: 18
                        color: root.bad ? Theme.error : Theme.primary
                    }
                }

                StyledText {
                    visible: root.problem
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.prob[1] + (root.prob[2] ? " <font color=\"" + Theme.surfaceVariantText + "\">· " + root.prob[2] + "</font>" : "")
                    textFormat: Text.StyledText
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                }

                RoundBtn {
                    visible: root.problem && root.st.can_retry === true
                    icon: "refresh"
                    onClicked: root.run(["retry"])
                }

                RoundBtn {
                    icon: "close"
                    onClicked: root.run(["cancel"])
                }
            }
        }
    }
}

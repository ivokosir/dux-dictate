import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.DCommon.Widgets
import qs.Modules.Plugins

// Runs once (daemon surface). Shows a notification-style card while you talk.
PluginComponent {
    id: root

    property var popoutService: null
    property string bin: Quickshell.env("HOME") + "/.local/bin/dictate"
    property var st: ({ daemon: false })
    property real nowMs: Date.now()
    // Mic loudness 0..1 while recording; the badge breathes with it.
    property real voice: 0

    readonly property string phase: st.daemon === true ? (st.state || "idle") : "idle"
    // When it's done, the card just goes away. It stays only for problems
    // (failed, or paste failed so the text is on the clipboard instead).
    readonly property bool shown: phase === "recording" || busy || phase === "error" || (phase === "done" && !!st.error)
    readonly property bool recording: phase === "recording"
    readonly property bool busy: phase === "transcribing" || phase === "cleaning"
    readonly property bool luna: st.mode === "luna"

    function run(args) {
        Quickshell.execDetached([root.bin].concat(args));
    }

    function clock(ms) {
        const s = Math.max(0, Math.floor(ms / 1000));
        return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");
    }

    Process {
        id: watcher
        command: [root.bin, "watch"]
        running: true
        stdout: SplitParser {
            onRead: data => {
                // "L 0.420" = mic level (~20x/s while recording): cheap path, no JSON.
                if (data.charCodeAt(0) === 76) {
                    const v = root.recording ? (Number(data.slice(2)) || 0) : 0;
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
        running: root.recording
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

    readonly property string title: {
        switch (phase) {
        case "recording":
            return "Listening";
        case "transcribing":
            return "Transcribing";
        case "cleaning":
            return "Cleaning up";
        case "done":
            return "Couldn't paste: it's on your clipboard";
        case "error":
            return "Didn't work";
        }
        return "";
    }

    readonly property string subtitle: {
        const parts = [];
        if (recording)
            parts.push(clock(nowMs - (Number(st.started_ms) || nowMs)));
        if (phase === "recording" || busy)
            parts.push(st.live ? "Live" : "ElevenLabs");
        if (luna)
            parts.push("Luna cleanup");
        return parts.join("  ·  ");
    }

    readonly property string bodyText: {
        if (phase === "error")
            return st.error || "";
        // Only live mode shows words, and only while you talk; never the final pasted text.
        if (phase !== "recording" || !st.live)
            return "";
        const t = st.text || "";
        return t.length > 260 ? "…" + t.slice(-260) : t;
    }

    readonly property color accent: phase === "error" ? Theme.error : recording ? Theme.error : Theme.primary

    // ---- small building blocks ------------------------------------------------

    component Btn: Rectangle {
        id: btn

        property string label: ""
        property string icon: ""
        property string kind: "text" // filled | tonal | text
        signal clicked

        implicitHeight: 34
        implicitWidth: row.implicitWidth + (kind === "text" ? 20 : 28)
        radius: height / 2
        color: {
            const base = kind === "filled" ? Theme.primary : kind === "tonal" ? Theme.withAlpha(Theme.primary, 0.16) : "transparent";
            return area.containsMouse ? Qt.tint(base, Theme.withAlpha(kind === "filled" ? Theme.onPrimary : Theme.primary, 0.1)) : base;
        }
        readonly property color fg: kind === "filled" ? Theme.onPrimary : Theme.primary

        Behavior on color {
            ColorAnimation { duration: 120 }
        }

        Row {
            id: row
            anchors.centerIn: parent
            spacing: 6

            DIcon {
                visible: btn.icon !== ""
                name: btn.icon
                size: 18
                color: btn.fg
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: btn.label
                color: btn.fg
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        MouseArea {
            id: area
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.clicked()
        }
    }

    // ---- the card --------------------------------------------------------------

    PanelWindow {
        id: win

        readonly property real pad: 16
        readonly property real cardWidth: 400

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

        margins {
            top: Math.max(0, topGap - pad)
            right: Math.max(0, Theme.popupDistance - pad)
        }

        implicitWidth: cardWidth + pad * 2
        implicitHeight: card.implicitHeight + pad * 2

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

            x: win.pad
            y: win.pad + (root.shown ? 0 : -14)
            width: win.cardWidth
            implicitHeight: content.implicitHeight + 32
            height: implicitHeight
            radius: Theme.windowRadius
            color: Theme.hostSurface
            border.color: root.recording ? Theme.withAlpha(Theme.error, 0.45) : Theme.outlineVariant
            border.width: 1
            opacity: root.shown ? 1 : 0
            clip: true

            Behavior on opacity {
                NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
            }
            Behavior on y {
                NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
            }
            Behavior on implicitHeight {
                NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
            }
            Behavior on border.color {
                ColorAnimation { duration: 200 }
            }

            Column {
                id: content

                x: 16
                y: 16
                width: parent.width - 32
                spacing: 12

                // header
                Item {
                    width: parent.width
                    height: 44

                    // Soft halo behind the badge: grows a little with your voice, smoothly.
                    Rectangle {
                        anchors.centerIn: badge
                        width: 44
                        height: 44
                        radius: 22
                        color: Theme.withAlpha(Theme.error, 0.22)
                        visible: root.recording
                        scale: 1 + root.voice * 0.32
                        opacity: 0.25 + root.voice * 0.75
                        Behavior on scale {
                            NumberAnimation { duration: 160; easing.type: Easing.OutQuad }
                        }
                        Behavior on opacity {
                            NumberAnimation { duration: 160; easing.type: Easing.OutQuad }
                        }
                    }

                    Rectangle {
                        id: badge
                        width: 44
                        height: 44
                        radius: 22
                        color: Theme.withAlpha(root.accent, 0.16)
                        anchors.verticalCenter: parent.verticalCenter

                        DIcon {
                            anchors.centerIn: parent
                            visible: !root.busy
                            name: root.recording ? "mic" : root.phase === "error" ? "error" : root.phase === "done" ? (root.st.error ? "content_paste" : "check") : "mic"
                            filled: true
                            size: 24
                            color: root.accent
                        }

                        DSpinner {
                            anchors.centerIn: parent
                            visible: root.busy
                            running: root.busy
                            size: 26
                            color: Theme.primary
                        }
                    }

                    Column {
                        anchors.left: badge.right
                        anchors.leftMargin: 12
                        anchors.right: closeBtn.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2

                        StyledText {
                            width: parent.width
                            text: root.title
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                        }

                        StyledText {
                            width: parent.width
                            visible: text !== ""
                            text: root.subtitle
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall
                            font.features: { "tnum": 1 }
                            elide: Text.ElideRight
                        }
                    }

                    Rectangle {
                        id: closeBtn
                        width: 32
                        height: 32
                        radius: 16
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        color: closeArea.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.08) : "transparent"

                        DIcon {
                            anchors.centerIn: parent
                            name: "close"
                            size: 20
                            color: Theme.surfaceVariantText
                        }

                        MouseArea {
                            id: closeArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.run(["cancel"])
                        }
                    }
                }

                // transcript / error text
                StyledText {
                    width: parent.width
                    visible: text !== ""
                    text: root.bodyText
                    color: root.phase === "error" ? Theme.error : root.phase === "recording" ? Theme.surfaceVariantText : Theme.surfaceText
                    font.pixelSize: Theme.fontSizeMedium
                    wrapMode: Text.WordWrap
                    maximumLineCount: 5
                    elide: Text.ElideRight
                    lineHeight: 1.15
                }

                // actions
                Row {
                    anchors.right: parent.right
                    spacing: 6
                    visible: root.recording || root.busy || root.phase === "error"

                    Btn {
                        label: "Cancel"
                        visible: root.recording || root.busy
                        onClicked: root.run(["cancel"])
                    }

                    Btn {
                        visible: root.recording
                        kind: "tonal"
                        icon: root.luna ? "notes" : "auto_awesome"
                        label: root.luna ? "Raw" : "Clean up"
                        onClicked: root.run(["stop", root.luna ? "direct" : "luna"])
                    }

                    Btn {
                        visible: root.recording
                        kind: "filled"
                        icon: "stop"
                        label: "Done"
                        onClicked: root.run(["stop"])
                    }

                    Btn {
                        visible: root.phase === "error"
                        label: "Dismiss"
                        onClicked: root.run(["cancel"])
                    }

                    Btn {
                        visible: root.phase === "error" && root.st.can_retry === true
                        kind: "filled"
                        icon: "refresh"
                        label: "Retry"
                        onClicked: root.run(["retry"])
                    }
                }
            }
        }
    }
}

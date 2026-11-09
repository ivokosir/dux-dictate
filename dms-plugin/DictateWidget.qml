import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.DCommon.Widgets
import qs.Modules.Plugins

// Bar button: left click starts/stops talking, right click opens settings + history.
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
    readonly property var history: up && st.history ? st.history : []

    function run(args) {
        Quickshell.execDetached([root.bin].concat(args));
    }

    function clock(ms) {
        const s = Math.max(0, Math.floor(ms / 1000));
        return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");
    }

    function ago(ms) {
        const s = Math.max(0, Math.round((nowMs - ms) / 1000));
        if (s < 60)
            return "just now";
        if (s < 3600)
            return Math.floor(s / 60) + " min ago";
        if (s < 86400)
            return Math.floor(s / 3600) + " h ago";
        return Math.floor(s / 86400) + " d ago";
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
                    const next = JSON.parse(data);
                    // Live words change the text often; the bar doesn't show text, so skip those.
                    const h = root.st.history, nh = next.history;
                    if (root.st.state === next.state && root.st.streaming === next.streaming && root.st.daemon === next.daemon
                            && root.st.configured === next.configured && root.st.started_ms === next.started_ms
                            && (h ? h.length : 0) === (nh ? nh.length : 0) && (!h || !h.length || h[0].at_ms === nh[0].at_ms))
                        return;
                    root.st = next;
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

    Timer {
        interval: 500
        repeat: true
        running: root.recording
        triggeredOnStart: true
        onTriggered: root.nowMs = Date.now()
    }

    property var _toggle: () => root.run(["toggle"])
    pillClickAction: _toggle
    pillRightClickAction: () => {
        // Open the popout instead of toggling.
        root.pillClickAction = null;
        root.nowMs = Date.now();
        root.triggerPopout();
        root.pillClickAction = root._toggle;
    }

    // ---- bar pill -------------------------------------------------------------

    readonly property color pillColor: phase === "down" ? Theme.error : recording ? Theme.error : busy ? Theme.primary : Theme.surfaceText

    component PillIcon: DIcon {
        id: pillIcon
        name: root.phase === "down" ? "mic_off" : root.busy ? "graphic_eq" : "mic"
        filled: root.recording || root.busy
        size: root.iconSize
        color: root.pillColor

        SequentialAnimation on opacity {
            running: root.busy
            loops: Animation.Infinite
            onRunningChanged: if (!running) pillIcon.opacity = 1
            NumberAnimation { to: 0.45; duration: 550; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1.0; duration: 550; easing.type: Easing.InOutQuad }
        }
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            PillIcon {
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                visible: root.recording
                text: root.clock(root.nowMs - (Number(root.st.started_ms) || root.nowMs))
                font.pixelSize: root.textSize
                font.features: { "tnum": 1 }
                color: root.pillColor
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 2

            PillIcon {
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                visible: root.recording
                text: root.clock(root.nowMs - (Number(root.st.started_ms) || root.nowMs))
                font.pixelSize: Theme.fontSizeSmall
                color: root.pillColor
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    // ---- popout (right click) ---------------------------------------------------

    popoutWidth: 380

    popoutContent: Component {
        PopoutComponent {
            id: popout

            Column {
                width: parent.width
                topPadding: Theme.spacingS
                bottomPadding: Theme.spacingS
                spacing: Theme.spacingM

                // header
                Item {
                    x: Theme.spacingS
                    width: parent.width - Theme.spacingS * 2
                    height: 44

                    Rectangle {
                        id: headIcon
                        width: 44
                        height: 44
                        radius: 22
                        color: root.recording ? Theme.error : Theme.primary

                        DIcon {
                            anchors.centerIn: parent
                            name: root.phase === "down" ? "mic_off" : "mic"
                            filled: true
                            size: 24
                            color: Theme.onPrimary
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.run(["toggle"])
                        }
                    }

                    Column {
                        anchors.left: headIcon.right
                        anchors.leftMargin: Theme.spacingM
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2

                        StyledText {
                            text: "Dictate"
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                        }

                        StyledText {
                            width: parent.width
                            text: root.phase === "down" ? "Service not running: systemctl --user start dictate"
                                : !root.st.configured ? "No ElevenLabs key: run dictate set-key"
                                : "Click the mic to talk · Mod+B raw · Mod+G Luna"
                            font.pixelSize: Theme.fontSizeSmall
                            color: root.phase === "down" || !root.st.configured ? Theme.error : Theme.surfaceVariantText
                            elide: Text.ElideRight
                        }
                    }
                }

                // streaming switch
                Rectangle {
                    x: Theme.spacingS
                    width: parent.width - Theme.spacingS * 2
                    height: 64
                    radius: Theme.cornerRadius
                    color: Theme.withAlpha(Theme.surfaceText, 0.05)

                    Column {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.spacingM
                        anchors.right: toggle.left
                        anchors.rightMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2

                        StyledText {
                            text: "Live transcription"
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                        }

                        StyledText {
                            width: parent.width
                            text: root.st.streaming ? "See words while you talk, faster result" : "Off: upload when you stop (most accurate)"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            elide: Text.ElideRight
                        }
                    }

                    DToggle {
                        id: toggle
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        checked: root.st.streaming === true
                        enabled: root.up
                        onToggled: checked => root.run(["streaming", checked ? "on" : "off"])
                    }
                }

                StyledText {
                    x: Theme.spacingS + 4
                    visible: root.history.length > 0
                    text: "Recent · click to copy"
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    color: Theme.surfaceVariantText
                }

                Column {
                    x: Theme.spacingS
                    width: parent.width - Theme.spacingS * 2
                    spacing: 4

                    Repeater {
                        model: root.history.slice(0, 8)

                        Rectangle {
                            id: item
                            required property var modelData
                            property bool copied: false
                            width: parent.width
                            height: itemCol.implicitHeight + 16
                            radius: Theme.cornerRadius
                            color: itemArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.1) : Theme.withAlpha(Theme.surfaceText, 0.04)

                            Column {
                                id: itemCol
                                x: 12
                                y: 8
                                width: parent.width - 24
                                spacing: 2

                                StyledText {
                                    width: parent.width
                                    text: item.modelData.text
                                    font.pixelSize: Theme.fontSizeMedium
                                    color: Theme.surfaceText
                                    wrapMode: Text.WordWrap
                                    maximumLineCount: 2
                                    elide: Text.ElideRight
                                }

                                StyledText {
                                    text: item.copied ? "Copied" : root.ago(item.modelData.at_ms) + (item.modelData.mode === "luna" ? " · Luna" : "")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: item.copied ? Theme.primary : Theme.surfaceVariantText
                                }
                            }

                            Timer {
                                id: copiedTimer
                                interval: 1200
                                onTriggered: item.copied = false
                            }

                            MouseArea {
                                id: itemArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    Quickshell.execDetached(["wl-copy", "--", item.modelData.text]);
                                    item.copied = true;
                                    copiedTimer.restart();
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

import Quickshell
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Intrusive break reminder: scrim + centered card, dismissable by clicking
// outside, pressing Escape, or the Dismiss button. Shown by the service via
// shell.summon(id, payload); hidden via shell.hide(id).
Item {
    id: root

    property var shell: null
    property var manifest: null
    property var service: null

    property bool opened: false
    property string task: ""
    property int minutes: 0

    property color background: Color.menu.background
    property color foreground: Color.menu.text
    property color border: Color.menu.border
    property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
    property color scrim: Color.menu.scrim
    readonly property int cornerRadius: Style.cornerRadius
    property int contentMargin: Style.spacing.panelPadding
    property int cardWidth: Math.min(Style.space(360), panel.width - Style.gapsOut * 2)
    property string fontFamily: Style.font.menuFamily

    function open(payloadJson) {
        var payload = ({})
        try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
        root.task = payload.task || (root.service && root.service.current ? root.service.current.task : "")
        root.minutes = Math.max(1, parseInt(payload.minutes, 10) || 0)
        root.opened = true
        Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }

    function close() {
        root.opened = false
    }

    function dismiss() {
        root.opened = false
        if (root.service && typeof root.service.dismissModal === "function")
            root.service.dismissModal()
        else if (root.shell && root.manifest && typeof root.shell.hide === "function")
            root.shell.hide(root.manifest.id)
    }

    PanelWindow {
        id: panel
        visible: root.opened
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.namespace: "omarchy-omatime"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore

        Rectangle {
            anchors.fill: parent
            color: root.scrim
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.dismiss()
        }

        BorderSurface {
            id: card
            width: root.cardWidth
            implicitHeight: content.implicitHeight + contentMargin * 2
            radius: root.cornerRadius
            anchors.centerIn: parent
            color: root.background
            borderSpec: root.borderSpec
            padding: contentMargin
            border.width: 2

            MouseArea { anchors.fill: parent; onClicked: {} }

            Item {
                id: keyCatcher
                anchors.fill: parent
                focus: true

                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape) {
                        root.dismiss()
                        event.accepted = true
                    }
                }
            }

            Column {
                id: content
                anchors.fill: parent
                anchors.topMargin: card.contentTopInset
                anchors.rightMargin: card.contentRightInset
                anchors.bottomMargin: card.contentBottomInset
                anchors.leftMargin: card.contentLeftInset
                spacing: Style.spacing.controlPaddingY

                Text {
                    text: "⏱"
                    color: "#a6e3a1"
                    font.pixelSize: Style.font.display
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Text {
                    text: "Time for a break"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.heading
                    font.bold: true
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Text {
                    text: root.task ? ("on " + Model.shortTask(root.task, 40)) : ""
                    visible: root.task !== ""
                    color: Qt.darker(root.foreground, 1.3)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    width: parent.width
                }

                Text {
                    text: root.minutes > 0
                        ? "Working " + Model.minLabel(root.minutes * 60) + " straight. Stand up, stretch, look away."
                        : "Stand up, stretch, look away."
                    color: Qt.darker(root.foreground, 1.3)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    width: parent.width
                }

                Item { width: 1; height: Style.spacing.controlPaddingY }

                Button {
                    text: "Dismiss"
                    fontSize: Style.font.body
                    anchors.horizontalCenter: parent.horizontalCenter
                    onClicked: root.dismiss()
                }
            }
        }
    }
}
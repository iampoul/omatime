import QtQuick
import QtQuick.Controls
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Bar pill: ⏱ <task> <elapsed> when tracking, ⏱ idle dimmed otherwise.
// Left-click toggles the panel. Middle-click stops the session.
BarWidget {
    id: root
    moduleName: "io.github.iampoul.omatime"

    property var service: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null
    readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

    function open() { if (panelLoader.item) panelLoader.item.open() }
    function close() { if (panelLoader.item) panelLoader.item.close() }
    function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
    readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
    function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

    function injectPanel() {
        var target = panelLoader.item
        if (!target) return
        target.bar = root.bar
        target.settings = root.settings
        target.anchorItem = pill
        target.hostWidget = root
        target.service = root.service
    }

    onBarChanged: {
        root.service = root.bar && root.bar.shell ? root.bar.shell.serviceFor(root.moduleName) : null
        injectPanel()
    }
    onSettingsChanged: { root.configureService(); injectPanel() }
    onServiceChanged: { injectPanel(); root.configureService() }
    Component.onCompleted: root.configureService()

    function configureService() {
        if (root.service && typeof root.service.configure === "function")
            root.service.configure(root.settings)
    }

    function stopCurrent() {
        if (root.service && root.service.running) root.service.stop()
    }

    visible: panelLoader.item ? true : root.service !== null
    implicitWidth: pill.implicitWidth + Style.space(12)
    implicitHeight: Math.max(pill.implicitHeight + Style.space(6), root.barSize)

    Loader {
        id: panelLoader
        active: true
        source: Qt.resolvedUrl("Panel.qml")
        visible: false
        onLoaded: {
            root.injectPanel()
            Qt.callLater(root.injectPanel)
        }
    }

    Row {
        id: pill
        anchors.centerIn: parent
        spacing: Style.space(6)

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.service && root.service.paused ? "⏸" : "⏱"
            color: root.service && root.service.running
                ? (root.service.paused ? "#f9e2af" : "#a6e3a1")
                : Qt.darker(root.bar ? root.bar.foreground : "#cdd6f4", 1.3)
            font.family: root.bar ? root.bar.fontFamily : "monospace"
            font.pixelSize: Style.font.caption
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: {
                if (root.service && root.service.running)
                    return Model.shortTask(root.service.current.task, 16)
                return "idle"
            }
            color: root.bar ? (root.service && root.service.running ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.4)) : "#a6adc8"
            font.family: root.bar ? root.bar.fontFamily : "monospace"
            font.pixelSize: Style.font.caption
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.service && root.service.running
            text: root.service ? "· " + Model.hmsLabel(root.service.elapsedSec) : ""
            color: root.bar ? Qt.darker(root.bar.foreground, 1.2) : "#9399b2"
            font.family: root.bar ? root.bar.fontFamily : "monospace"
            font.pixelSize: Style.font.caption
        }
    }

    MouseArea {
        id: pillArea
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        hoverEnabled: true

        onClicked: function(mouse) {
            if (mouse.button === Qt.MiddleButton) {
                root.stopCurrent()
            } else {
                root.togglePanel()
            }
        }
    }
}
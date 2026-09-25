import QtQuick
import QtQuick.Controls
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
    id: root

    moduleName: "io.github.iampoul.omatime"
    manageIpc: false
    property var anchorItem: null
    property var hostWidget: null
    property var service: null

    // Composed from per-task totals so the pill sub-label can reuse it.
    readonly property var taskNames: service && service.todayTasks ? service.todayTasks.map(t => t.name) : []

    // Active tab: 0 Start · 1 Timer · 2 Graph · 3 Settings
    property int viewIndex: 0

    // Escalation state: a new task was entered while one was running; the
    // switch is held here until the user confirms (stops the old session) or
    // cancels. Guarded by the running state so a stop elsewhere untangles it.
    property string pendingSwitch: ""

    // Re-pull the period stats whenever the Graph tab is opened.
    onViewIndexChanged: { if (viewIndex === 2 && root.service) root.service.refreshRange() }

    function open() {
        root.viewIndex = root.service && root.service.running ? 1 : 0
        root.controller.show()
    }
    function close() { root.controller.hide() }
    function toggle() { root.opened ? root.close() : root.open() }

    KeyboardPanel {
        id: panel
        anchorItem: root.anchorItem
        owner: root.hostWidget || root
        bar: root.bar
        open: root.opened
        contentWidth: panel.fittedContentWidth(Style.space(460))
        contentHeight: panel.fittedContentHeight(body.implicitHeight)
        focusTarget: taskInput

        Flickable {
            id: scroll
            anchors.fill: parent
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height || contentWidth > width
            contentWidth: body.width
            contentHeight: body.implicitHeight

            Column {
                id: body
                width: scroll.width
                spacing: 14

                // Header
                Row {
                    width: parent.width
                    spacing: 8

                    Text {
                        id: titleText
                        text: "⏱ omaTime"
                        color: root.bar ? root.bar.foreground : "white"
                        font.bold: true
                        font.pixelSize: Style.font.subtitle
                        font.family: root.bar ? root.bar.fontFamily : "monospace"
                    }

                    Item { width: Math.max(0, parent.width - titleText.implicitWidth - totalText.implicitWidth - parent.spacing * 2); height: 1 }

                    Text {
                        id: totalText
                        anchors.verticalCenter: parent.verticalCenter
                        text: "today " + Model.minLabel(root.service ? root.service.todayTotal : 0)
                        color: "#a6e3a1"
                        font.family: root.bar ? root.bar.fontFamily : "monospace"
                        font.pixelSize: Style.font.caption
                    }
                }

                PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

                // Tab bar
                Row {
                    id: tabRow
                    width: parent.width
                    spacing: 6

                    Repeater {
                        model: ["Start", "Timer", "Graph", "Settings"]
                        delegate: Button {
                            required property int index
                            required property string modelData
                            width: (tabRow.width - tabRow.spacing * 3) / 4
                            text: modelData
                            selected: root.viewIndex === index
                            fontSize: Style.font.bodySmall
                            onClicked: root.viewIndex = index
                        }
                    }
                }

                PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

                // ------------------------------------------------------ Start
                Column {
                    width: parent.width
                    spacing: 8
                    visible: root.viewIndex === 0

                    // Confirm bar: shown when a start was entered while a
                    // session is already running. The old session only stops
                    // once the user confirms the switch.
                    Rectangle {
                        width: parent.width
                        visible: root.pendingSwitch !== ""
                        radius: 6
                        color: Qt.rgba(243, 139, 168, 0.12)
                        height: confirmCol.implicitHeight + 20

                        Column {
                            id: confirmCol
                            width: parent.width - 20
                            spacing: 6
                            anchors.top: parent.top
                            anchors.left: parent.left
                            anchors.margins: 10
                            topPadding: 10
                            bottomPadding: 10

                            Text {
                                width: parent.width
                                text: "A timer is running: " + (root.service && root.service.current ? Model.shortTask(root.service.current.task, 24) : "?")
                                color: "#f38ba8"
                                font.family: root.bar ? root.bar.fontFamily : "monospace"
                                font.pixelSize: Style.font.caption
                                elide: Text.ElideRight
                            }

                            Row {
                                width: parent.width
                                spacing: 8

                                Button {
                                    text: "Switch to '" + Model.shortTask(root.pendingSwitch, 14) + "'"
                                    fontSize: Style.font.bodySmall
                                    foreground: "#a6e3a1"
                                    onClicked: root.confirmSwitch()
                                }

                                Button {
                                    text: "✕ Cancel"
                                    fontSize: Style.font.bodySmall
                                    foreground: root.bar ? root.bar.foreground : Color.foreground
                                    onClicked: root.cancelSwitch()
                                }
                            }
                        }
                    }

                    Row {
                        width: parent.width
                        spacing: 8

                        TextField {
                            id: taskInput
                            width: parent.width - startButton.implicitWidth - parent.spacing
                            foreground: root.bar ? root.bar.foreground : Color.foreground
                            placeholderText: root.service && root.service.running
                                ? "New task (Enter to switch)"
                                : "What are you working on?"
                            text: ""
                            onTextEdited: if (root.pendingSwitch !== "") root.pendingSwitch = ""
                            onAccepted: root.commitTask()
                        }

                        Button {
                            id: startButton
                            text: "▶ Start"
                            foreground: "#a6e3a1"
                            onClicked: root.commitTask()
                        }
                    }

                    // Suggestions from previously used tasks
                    Flow {
                        width: parent.width
                        spacing: 6
                        visible: taskInput.activeFocus && taskInput.text.length === 0 && recentTasks.length > 0
                        Repeater {
                            model: recentTasks
                            delegate: Button {
                                required property string modelData
                                text: modelData
                                fontSize: Style.font.bodySmall
                                onClicked: {
                                    taskInput.text = modelData
                                    taskInput.forceActiveFocus()
                                }
                            }
                        }
                    }
                }

                // ------------------------------------------------------ Timer
                Column {
                    width: parent.width
                    spacing: 8
                    visible: root.viewIndex === 1

                    // Running session card
                    Column {
                        width: parent.width
                        spacing: 8
                        visible: root.service && root.service.running

                        Rectangle {
                            width: parent.width
                            height: 14
                            radius: 6
                            color: Qt.rgba(1, 1, 1, 0.06)

                            Rectangle {
                                width: Math.max(14, parent.width * Math.min(1, (root.service ? root.service.elapsedSec : 0) / (root.service ? root.service.breakIntervalSec : 1)))
                                height: parent.height
                                radius: 6
                                color: root.service && root.service.paused ? "#f9e2af"
                                    : root.service && root.service.breakNextInSec <= 300 ? "#fab387" : "#a6e3a1"
                                Behavior on width { NumberAnimation { duration: 1000 } }
                            }
                        }

                        Row {
                            width: parent.width
                            spacing: 8

                            Column {
                                width: parent.width - elapsedText.implicitWidth - parent.spacing
                                spacing: 3

                                Text {
                                    text: root.service && root.service.current ? root.service.current.task : ""
                                    color: root.bar ? root.bar.foreground : "white"
                                    font.family: root.bar ? root.bar.fontFamily : "monospace"
                                    font.pixelSize: Style.font.body
                                    elide: Text.ElideRight
                                    width: parent.width
                                }

                                Text {
                                    text: root.service && root.service.current ? (root.service.current.note || "—") : ""
                                    color: Qt.darker(root.bar ? root.bar.foreground : "white", 1.4)
                                    font.family: root.bar ? root.bar.fontFamily : "monospace"
                                    font.pixelSize: Style.font.caption
                                    elide: Text.ElideRight
                                    width: parent.width
                                }
                            }

                            Text {
                                id: elapsedText
                                anchors.verticalCenter: parent.verticalCenter
                                text: (root.service && root.service.paused ? "⏸ " : "") + (root.service ? Model.hmsLabel(root.service.elapsedSec) : "--:--:--")
                                color: "#89b4fa"
                                font.family: root.bar ? root.bar.fontFamily : "monospace"
                                font.pixelSize: Style.font.bodySmall
                                font.bold: true
                            }
                        }

                        Row {
                            width: parent.width
                            spacing: 8

                            Button {
                                id: pauseBtn
                                text: root.service && root.service.paused ? "▶ Resume" : "⏸ Pause"
                                fontSize: Style.font.bodySmall
                                selected: root.service && root.service.paused
                                foreground: root.service && root.service.paused ? "#a6e3a1" : (root.bar ? root.bar.foreground : Color.foreground)
                                onClicked: {
                                    if (!root.service) return
                                    if (root.service.paused) root.service.resume()
                                    else root.service.pause()
                                }
                            }

                            Button {
                                id: stopButton
                                text: "■ Stop"
                                fontSize: Style.font.bodySmall
                                foreground: "#f38ba8"
                                onClicked: { if (root.service) root.service.stop() }
                            }

                            Item { width: Math.max(0, parent.width - pauseBtn.implicitWidth - stopButton.implicitWidth - parent.spacing * 2); height: 1 }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: (root.service && root.service.breakNextInSec > 0)
                                    ? "break in " + Model.minLabel(root.service.breakNextInSec)
                                    : (root.service && root.service.running ? "break due!" : "")
                                color: root.service && root.service.breakNextInSec <= 300 ? "#fab387" : "#9399b2"
                                font.family: root.bar ? root.bar.fontFamily : "monospace"
                                font.pixelSize: Style.font.caption
                            }
                        }

                        // Note
                        TextField {
                            id: noteField
                            width: parent.width
                            foreground: root.bar ? root.bar.foreground : Color.foreground
                            placeholderText: "Note: what are you doing?"
                            text: root.service ? root.service.currentNote() : ""
                            onAccepted: { if (root.service) root.service.setNote(noteField.text) }
                            Keys.onEscapePressed: focus = false
                        }

                        // Tags: edit input + chips
                        TextField {
                            id: tagField
                            width: parent.width
                            foreground: root.bar ? root.bar.foreground : Color.foreground
                            placeholderText: "Add tag (Enter)"
                            onAccepted: {
                                if (root.service) {
                                    root.service.addTag(text.trim())
                                    text = ""
                                }
                            }
                        }

                        Flow {
                            width: parent.width
                            spacing: 6
                            visible: root.service && root.service.currentTags().length > 0
                            Repeater {
                                model: root.service ? root.service.currentTags() : []
                                delegate: Row {
                                    required property string modelData
                                    spacing: 4
                                    Button {
                                        text: modelData + "  ✕"
                                        fontSize: Style.font.bodySmall
                                        foreground: "#1e1e2e"
                                        background: Model.tagColor(modelData)
                                        onClicked: root.service.removeTag(modelData)
                                    }
                                }
                            }
                        }
                    }

                    Text {
                        width: parent.width
                        visible: !root.service || !root.service.running
                        text: "No active timer — start one in Start."
                        color: "#6c7086"
                        font.family: root.bar ? root.bar.fontFamily : "monospace"
                        font.pixelSize: Style.font.caption
                    }
                }

                // ------------------------------------------------------ Graph
                Column {
                    width: parent.width
                    spacing: 8
                    visible: root.viewIndex === 2

                    // Period toggle: day | week | month
                    Row {
                        width: parent.width
                        spacing: 6
                        Repeater {
                            model: ["TODAY", "WEEK", "MONTH"]
                            delegate: Button {
                                required property int index
                                required property string modelData
                                width: (parent.width - parent.spacing * 2) / 3
                                text: modelData
                                selected: root.service && root.service.graphScope === index
                                fontSize: Style.font.bodySmall
                                onClicked: { if (root.service) root.service.graphScope = index }
                            }
                        }
                    }

                    PanelSectionHeader {
                        text: (root.service ? root.service.rangeTitle : "TODAY") + " · " + Model.minLabel(root.service ? root.service.rangeTotal : 0)
                        foreground: root.bar ? root.bar.foreground : Color.foreground
                        fontFamily: root.bar ? root.bar.fontFamily : "monospace"
                    }

                    // Per-day totals over the period
                    Rectangle {
                        width: parent.width
                        height: 86
                        radius: 6
                        color: Qt.rgba(1, 1, 1, 0.05)
                        clip: true
                        visible: root.service && root.service.rangeDays.length > 1

                        Canvas {
                            id: dayBars
                            anchors.fill: parent
                            antialiasing: true
                            onPaint: Model.drawDayBars(getContext("2d"), root.service ? root.service.rangeDays : [], width, height)
                            Connections {
                                target: root.service
                                function onRangeDaysChanged() { dayBars.requestPaint() }
                            }
                        }
                    }

                    Text {
                        width: parent.width
                        visible: root.service && root.service.rangeDays.length > 1 && root.service.rangeTotal === 0
                        text: "Nothing tracked yet in this period."
                        color: "#6c7086"
                        font.family: root.bar ? root.bar.fontFamily : "monospace"
                        font.pixelSize: Style.font.caption
                    }

                    // Per-task breakdown: vertical bars, height ∝ share of period
                    Rectangle {
                        width: parent.width
                        height: 86
                        visible: root.service && root.service.rangeTasks.length > 0
                        radius: 6
                        color: Qt.rgba(1, 1, 1, 0.05)
                        clip: true

                        Canvas {
                            id: taskBars
                            anchors.fill: parent
                            antialiasing: true
                            onPaint: Model.drawTaskBars(getContext("2d"),
                                root.service ? root.service.rangeTasks : [],
                                root.service ? root.service.rangeTotal : 0,
                                root.service ? root.service.rangeSessions : [],
                                width, height)
                            Connections {
                                target: root.service
                                function onRangeSessionsChanged() { taskBars.requestPaint() }
                                function onRangeTotalChanged() { taskBars.requestPaint() }
                            }
                        }
                    }

                    Text {
                        width: parent.width
                        visible: !root.service || root.service.rangeTasks.length === 0
                        text: "Nothing tracked yet in this period."
                        color: "#6c7086"
                        font.family: root.bar ? root.bar.fontFamily : "monospace"
                        font.pixelSize: Style.font.caption
                    }

                    PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

                    // Session list
                    Column {
                        width: parent.width
                        spacing: 6
                        visible: root.service && root.service.rangeSessions.length > 0

                        PanelSectionHeader {
                            text: "SESSIONS"
                            foreground: root.bar ? root.bar.foreground : Color.foreground
                            fontFamily: root.bar ? root.bar.fontFamily : "monospace"
                        }

                        Repeater {
                            model: root.service ? root.service.rangeSessions : []
                            delegate: Column {
                                required property var modelData
                                width: parent.width
                                spacing: 2

                                Row {
                                    width: parent.width
                                    spacing: 8
                                    Text {
                                        id: timeText
                                        width: 92
                                        text: Model.formatDaySpan(modelData.end, modelData.start, modelData.paused_sec || 0)
                                        color: Qt.darker(root.bar ? root.bar.foreground : "white", 1.4)
                                        font.family: root.bar ? root.bar.fontFamily : "monospace"
                                        font.pixelSize: Style.font.caption
                                    }
                                    Text {
                                        id: taskNameText
                                        text: Model.shortTask(modelData.task, 20)
                                        color: root.bar ? root.bar.foreground : "white"
                                        font.family: root.bar ? root.bar.fontFamily : "monospace"
                                        font.pixelSize: Style.font.bodySmall
                                        elide: Text.ElideRight
                                    }
                                    Item { width: Math.max(0, parent.width - timeText.implicitWidth - taskNameText.implicitWidth - parent.spacing * 2); height: 1 }
                                    Text {
                                        id: durText
                                        text: serviceActive(modelData)
                                        color: "#9399b2"
                                        font.family: root.bar ? root.bar.fontFamily : "monospace"
                                        font.pixelSize: Style.font.caption
                                    }
                                }
                                Text {
                                    width: parent.width
                                    visible: modelData.note !== ""
                                    text: "   " + modelData.note
                                    color: "#6c7086"
                                    font.family: root.bar ? root.bar.fontFamily : "monospace"
                                    font.pixelSize: Style.font.caption
                                    elide: Text.ElideRight
                                }
                            }
                        }
                    }
                }

                // --------------------------------------------------- Settings
                Column {
                    width: parent.width
                    spacing: 8
                    visible: root.viewIndex === 3

                    PanelSectionHeader {
                        text: "BREAK"
                        foreground: root.bar ? root.bar.foreground : Color.foreground
                        fontFamily: root.bar ? root.bar.fontFamily : "monospace"
                    }

                    Row {
                        width: parent.width
                        spacing: 8

                        Button {
                            id: enabledToggle
                            text: root.service && root.service.breakEnabled ? "enabled" : "disabled"
                            fontSize: Style.font.bodySmall
                            selected: root.service && root.service.breakEnabled
                            foreground: root.service && root.service.breakEnabled ? "#a6e3a1" : (root.bar ? root.bar.foreground : Color.foreground)
                            onClicked: { if (root.service) root.service.setBreakEnabled(!root.service.breakEnabled) }
                        }

                        Text {
                            id: breakLabel
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Remind me every"
                            color: Qt.darker(root.bar ? root.bar.foreground : "white", 1.3)
                            font.family: root.bar ? root.bar.fontFamily : "monospace"
                            font.pixelSize: Style.font.bodySmall
                        }

                        Button { id: minusBtn; text: "−"; onClicked: root.nudgeBreak(-5) }
                        Text {
                            id: breakValue
                            anchors.verticalCenter: parent.verticalCenter
                            width: 70
                            horizontalAlignment: Text.AlignHCenter
                            text: (root.service ? root.service.breakMinutes : 50) + " min"
                            color: root.bar ? root.bar.foreground : "white"
                            font.family: root.bar ? root.bar.fontFamily : "monospace"
                            font.pixelSize: Style.font.bodySmall
                            font.bold: true
                        }
                        Button { id: plusBtn; text: "+"; onClicked: root.nudgeBreak(5) }
                    }

                    Row {
                        width: parent.width
                        spacing: 8

                        Text {
                            id: modeLabel
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Remind via"
                            color: Qt.darker(root.bar ? root.bar.foreground : "white", 1.3)
                            font.family: root.bar ? root.bar.fontFamily : "monospace"
                            font.pixelSize: Style.font.bodySmall
                        }

                        Item { width: Math.max(0, parent.width - modeLabel.implicitWidth - notifyBtn.implicitWidth - popupBtn.implicitWidth - parent.spacing * 4); height: 1 }

                        Button {
                            id: notifyBtn
                            text: "notification"
                            selected: root.service ? root.service.breakMode === "notification" : true
                            fontSize: Style.font.bodySmall
                            onClicked: { if (root.service) root.service.setBreakMode("notification") }
                        }
                        Button {
                            id: popupBtn
                            text: "popup"
                            selected: root.service ? root.service.breakMode === "modal" : false
                            fontSize: Style.font.bodySmall
                            onClicked: { if (root.service) root.service.setBreakMode("modal") }
                        }
                    }

                    Text {
                        width: parent.width
                        visible: root.service && root.service.breakMode === "modal"
                        text: "The popup pauses the timer; it resumes when dismissed."
                        color: Qt.darker(root.bar ? root.bar.foreground : "white", 1.5)
                        font.family: root.bar ? root.bar.fontFamily : "monospace"
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                    }
                }

                Item { width: 1; height: 1 }
            }
        }
    }

    readonly property var recentTasks: root.service ? root.service.tasks : []

    function serviceActive(modelData) {
        return Model.minLabel(typeof modelData.sec === "number" ? modelData.sec : (modelData.end - modelData.start))
    }

    function commitTask() {
        var name = taskInput.text.trim()
        if (!name) return
        // A session is already running: escalate instead of silently
        // clobbering it. The confirmed switch (or a running->idle change
        // while the prompt is up) proceeds below.
        if (root.service && root.service.running && root.pendingSwitch === "") {
            root.pendingSwitch = name
            taskInput.text = ""
            taskInput.forceActiveFocus()
            return
        }
        root.pendingSwitch = ""
        root.service.startTask(name)
        taskInput.text = ""
        root.viewIndex = 1
        taskInput.forceActiveFocus()
    }

    function confirmSwitch() {
        var name = root.pendingSwitch
        root.pendingSwitch = ""
        if (!name) return
        root.service.startTask(name)
        taskInput.text = ""
        root.viewIndex = 1
        taskInput.forceActiveFocus()
    }

    function cancelSwitch() {
        root.pendingSwitch = ""
        taskInput.forceActiveFocus()
    }

    function nudgeBreak(delta) {
        var next = (root.service ? root.service.breakMinutes : 50) + delta
        next = Math.max(5, Math.min(240, next))
        if (root.service && typeof root.service.setBreakMinutes === "function")
            root.service.setBreakMinutes(next)
    }
}
import QtQuick
import Quickshell.Io
import "Model.js" as Model

// Background service for omaTime: owns the single live session, persists
// state through omatime-db.sh, fires break reminders, and answers lookups
// (tasks/tags/today). The bar widget and panel read from this instance via
// bar.shell.serviceFor("io.github.iampoul.omatime").
Item {
    id: root

    property var settings: ({})
    property var shell: null

    // Live session — null when idle.
    property var current: null
    property bool running: current !== null
    property int elapsedSec: 0
    // Paused while the intrusive modal break popup is up (auto-paused by the
    // break, resumed on dismiss). Manual pause/resume goes through the same
    // DB-backed paused_sec/paused_at fields.
    readonly property bool paused: root.current && (parseInt(root.current.paused_at, 10) || 0) > 0
    readonly property string durationLabel: Model.hmsLabel(elapsedSec)
    readonly property string clockLabel: Model.clockLabel(current ? current.start : 0, elapsedSec)

    // Global break settings (SQLite `settings` table). Loaded from the DB at
    // configure(); the panel edits them through the setters below.
    property bool breakEnabled: true
    property int breakMinutes: 50
    property string breakMode: "notification" // "notification" | "modal"
    readonly property bool runningBreak: running && breakEnabled
    readonly property int breakIntervalSec: breakMinutes * 60

    // Break reminder state.
    property int nextBreakSec: -1
    property int lastNotifiedBreak: -1
    // True while the intrusive popup's auto-pause holds the clock; only that
    // pause is released on dismiss, never a manual pause.
    property bool breakAutoPaused: false
    readonly property int breakNextInSec: nextBreakSec > 0 ? Math.max(0, nextBreakSec - elapsedSec) : -1
    readonly property string breakLabel: breakNextInSec > 0 ? Model.minLabel(breakNextInSec) : ""

    // Lookup caches.
    property var tasks: []
    property var tags: []
    property var todaySessions: []
    property var todayTasks: []
    property int todayTotal: 0

    // Period graph data (0=day, 1=week, 2=month). Repopulated by
    // refreshRange(); the Graph tab renders rangeDays / rangeTasks.
    property int graphScope: 0
    property var rangeSessions: []
    property var rangeDays: []
    property var rangeTasks: []
    property int rangeTotal: 0
    property string rangeTitle: "TODAY"

    property bool configuredOnce: false
    property bool dbBusy: false
    property var opQueue: []

    function setting(key, fallback) {
        var value = settings && settings[key]
        return value === undefined || value === null ? fallback : value
    }

    function dbPath() {
        return Qt.resolvedUrl("omatime-db.sh").toString().replace("file://", "")
    }

    function configure(nextSettings) {
        settings = nextSettings || ({})
        tickTimer.restart()
        refreshSettings()
        if (configuredOnce) return
        configuredOnce = true
        exec(["current"], (out) => { root.current = out && out.task ? out : null })
        refreshToday()
        refreshRange()
        refreshTasks()
        refreshTags()
    }

    // Global break settings — loaded from the SQLite `settings` table so the
    // values are shared across every bar instance and survive re-layout.
    function refreshSettings() {
        exec(["get", "breakEnabled", "true"], (out) => { if (typeof out === "string") root.breakEnabled = out !== "false" })
        exec(["get", "breakMinutes", "50"], (out) => { if (typeof out === "string") root.breakMinutes = Math.max(1, parseInt(out, 10) || 50) })
        exec(["get", "breakMode", "notification"], (out) => {
            if (typeof out === "string" && (out === "notification" || out === "modal"))
                root.breakMode = out
        })
    }

    function setBreakEnabled(enabled) {
        root.breakEnabled = !!enabled
        exec(["set", "breakEnabled", root.breakEnabled ? "true" : "false"], () => {})
    }

    function setBreakMinutes(minutes) {
        var next = Math.max(5, Math.min(240, parseInt(minutes, 10) || 50))
        root.breakMinutes = next
        exec(["set", "breakMinutes", String(next)], () => {})
    }

    function setBreakMode(mode) {
        var next = mode === "modal" ? "modal" : "notification"
        root.breakMode = next
        exec(["set", "breakMode", next], () => {})
    }

    function db(args, cb) {
        opQueue.push({ args: args, cb: cb })
        pumpDb()
    }

    function pumpDb() {
        if (dbBusy || opQueue.length === 0) return
        var op = opQueue.shift()
        dbBusy = true
        dbProc.cb = op.cb
        dbProc.command = [dbPath()].concat(op.args)
        dbProc.running = true
    }

    function exec(args, cb) {
        db(args, cb)
    }

    // --- actions -----------------------------------------------------------

    function startTask(name, note, tagList) {
        var task = String(name || "").trim()
        if (!task) return
        var tagsJson = JSON.stringify(Array.isArray(tagList) ? tagList : (Model.parseTags(tagList) || []))
        exec(["start", task, note || "", tagsJson], (out) => { root.current = out && out.task ? out : null })
        refreshToday()
        refreshRange()
        refreshTasks()
        refreshTags()
    }

    function switchTo(name, note, tags) {
        startTask(name, note, tags)
    }

    function stop() {
        if (!root.running) return
        exec(["stop"], (out) => { root.current = null })
        refreshToday()
        refreshRange()
    }

    function setNote(text) {
        if (!root.running) return
        exec(["note", text || ""], (out) => { root.current = out && out.task ? out : null })
    }

    // Pause/resume refuse when idle or already in the requested state, and
    // never touch break bookkeeping — the session id is unchanged.
    function pause() {
        if (!root.running || root.paused) return
        exec(["pause"], (out) => { root.current = out && out.task ? out : null })
    }

    function resume() {
        if (!root.running || !root.paused) return
        exec(["resume"], (out) => { root.current = out && out.task ? out : null })
    }

    function setTags(tagList) {
        if (!root.running) return
        var tagsJson = JSON.stringify(Array.isArray(tagList) ? tagList : [])
        exec(["tags", tagsJson], (out) => { root.current = out && out.task ? out : null })
        refreshTags()
    }

    function addTag(name) {
        if (!root.running || !name) return
        var merged = Model.mergeTags(root.current && root.current.tags, [name])
        setTags(merged)
    }

    function removeTag(name) {
        if (!root.running || !name) return
        var merged = Model.mergeTags(root.current && root.current.tags, [], [name])
        setTags(merged)
    }

    // --- lookups -----------------------------------------------------------

    function refreshToday() {
        exec(["today"], (out) => {
            if (!out) return
            root.todaySessions = out.sessions || []
            root.todayTasks = out.tasks || []
            root.todayTotal = out.total || 0
        })
    }

    function refreshRange() {
        var scope = ["day", "week", "month"][root.graphScope] || "day"
        exec(["range", scope], (out) => {
            if (!out) return
            root.rangeSessions = out.sessions || []
            root.rangeDays = out.days || []
            root.rangeTasks = out.tasks || []
            root.rangeTotal = out.total || 0
            root.rangeTitle = out.title || "TODAY"
        })
    }

    onGraphScopeChanged: refreshRange()

    function refreshTasks() {
        exec(["tasks"], (out) => { root.tasks = Array.isArray(out) ? out : [] })
    }

    function refreshTags() {
        exec(["taglist"], (out) => { root.tags = Array.isArray(out) ? out : [] })
    }

    function suggestTasks(q) {
        exec(["tasks", q || ""], (out) => { root.tasks = Array.isArray(out) ? out : [] })
    }

    function suggestTags(q) {
        exec(["taglist", q || ""], (out) => { root.tags = Array.isArray(out) ? out : [] })
    }

    function currentTags() {
        return Model.parseTags(root.current && root.current.tags)
    }

    function currentNote() {
        return (root.current && root.current.note) || ""
    }

    // --- bookkeeping -------------------------------------------------------

    // Bookkeeping resets only when the tracked session identity changes
    // (id differs / new session / idle). Note/tags/pause/resume refresh
    // `current` in place with the same id and must not touch the clock.
    property int currentId: -1

    onCurrentChanged: {
        var id = root.running ? parseInt(root.current.id, 10) || 0 : 0
        if (id !== root.currentId) {
            root.currentId = id
            elapsedSec = 0
            lastNotifiedBreak = -1
            nextBreakSec = breakIntervalSec
        }
        tickTimer.restart()
    }

    Timer {
        id: tickTimer
        interval: 1000
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (!root.running) {
                elapsedSec = 0
                nextBreakSec = breakIntervalSec
                return
            }
            var base = root.current && root.current.start ? parseInt(root.current.start, 10) : 0
            var pausedSec = root.current ? (parseInt(root.current.paused_sec, 10) || 0) : 0
            var pausedAt = root.current ? (parseInt(root.current.paused_at, 10) || 0) : 0
            if (base > 0) {
                // Active = wall time minus accumulated paused time, frozen at
                // the pause boundary while the clock is stopped.
                var nowSec = Math.floor(Date.now() / 1000)
                var effUntil = pausedAt > 0 ? pausedAt : nowSec
                elapsedSec = Math.max(0, effUntil - base - pausedSec)
            } else {
                elapsedSec += 1
            }
            if (!root.breakEnabled) {
                nextBreakSec = -1
                return
            }
            var multiple = Math.floor(elapsedSec / breakIntervalSec)
            nextBreakSec = (multiple + 1) * breakIntervalSec
            if (multiple > lastNotifiedBreak) {
                lastNotifiedBreak = multiple
                if (multiple >= 1) notifyBreak()
            }
        }
    }

    function notifyBreak() {
        var mins = Math.floor(elapsedSec / 60)
        var task = (root.current && root.current.task) || ""
        if (root.breakMode === "modal") {
            // Intrusive center-screen card, dismissable. The timer stays
            // paused until the popup is dismissed (see dismissModal), so the
            // pause is a real work-time break, not ambient noise.
            // lastNotifiedBreak already advanced to this interval, so the
            // next nudge only fires at the following interval boundary — no
            // immediate re-pop while dismissed.
            root.breakAutoPaused = true
            if (!root.paused) root.pause()
            var payload = JSON.stringify({ task: task, minutes: Math.max(1, mins), start: root.current ? root.current.start : 0 })
            if (root.shell && typeof root.shell.summon === "function")
                root.shell.summon("io.github.iampoul.omatime", payload)
            return
        }
        notifyProc.exec([
            "-g", "",
            "-u", "normal",
            "--app-name", "omaTime",
            "Break time",
            "You've been on '" + task + "' for " + Model.minLabel(mins * 60) + " — stand up, stretch, look away."
        ])
    }

    function dismissModal() {
        if (root.shell && typeof root.shell.hide === "function")
            root.shell.hide("io.github.iampoul.omatime")
        // Popup paused the clock; resume it now that the break is over. Only
        // the break-induced pause is released — a manual pause stays put.
        if (root.breakAutoPaused) {
            root.breakAutoPaused = false
            if (root.paused) root.resume()
        }
    }

    Process {
        id: dbProc
        property var cb: null
        stdout: StdioCollector { id: dbOut; waitForEnd: true }
        stderr: StdioCollector { id: dbErr; waitForEnd: true }
        onExited: (exitCode) => {
            var body = dbOut.text.trim()
            var parsed = null
            if (exitCode === 0 && body) {
                try { parsed = JSON.parse(body) } catch (e) {}
            }
            if (exitCode !== 0)
                console.log("omarchy-omatime: db error:", dbErr.text.trim() || dbOut.text.trim())
            if (dbProc.cb) dbProc.cb(parsed)
            dbProc.cb = null
            dbBusy = false
            pumpDb()
        }
    }

    Process {
        id: notifyProc
        command: ["omarchy-notification-send"]
        stdout: StdioCollector { waitForEnd: true }
        stderr: StdioCollector { waitForEnd: true }
    }
}
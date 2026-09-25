.pragma library

function parseTags(raw) {
    if (Array.isArray(raw)) return raw.slice()
    if (typeof raw === "string" && raw) {
        try { return JSON.parse(raw) } catch (e) {}
    }
    return []
}

// Merge newTags in (dedup, keep order), optionally removing removeTags.
function mergeTags(cur, add, remove) {
    var base = parseTags(cur)
    var out = []
    var seen = {}
    var i, t
    function push(x) {
        var v = String(x || "").trim().toLowerCase()
        if (!v || seen[v]) return
        seen[v] = true
        out.push(x)
    }
    for (i = 0; i < base.length; i++) push(base[i])
    for (i = 0; i < (add || []).length; i++) push(add[i])
    if (remove) {
        var rem = {}
        for (i = 0; i < remove.length; i++) rem[String(remove[i]).toLowerCase()] = true
        for (i = out.length - 1; i >= 0; i--) {
            if (rem[String(out[i]).toLowerCase()]) out.splice(i, 1)
        }
    }
    return out
}

function pad2(n) { return n < 10 ? "0" + n : "" + n }

// "1h 12m" / "45m" / "12s"
function minLabel(seconds) {
    seconds = Math.max(0, Math.round(Number(seconds) || 0))
    var s = seconds % 60
    var m = Math.floor(seconds / 60) % 60
    var h = Math.floor(seconds / 3600)
    if (h > 0) return h + "h " + m + "m"
    if (m > 0) return m + "m"
    return s + "s"
}

// "01:23:45" always
function hmsLabel(seconds) {
    seconds = Math.max(0, Math.round(Number(seconds) || 0))
    return pad2(Math.floor(seconds / 3600)) + ":" + pad2(Math.floor(seconds / 60) % 60) + ":" + pad2(seconds % 60)
}

// Wall clock "14:05" for start base + elapsed
function clockLabel(startSec, elapsed) {
    var base = parseInt(startSec, 10) || 0
    if (base <= 0) return "--:--"
    var d = new Date(base * 1000)
    return pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

function formatDayStart(startSec) {
    var d = new Date(parseInt(startSec, 10) * 1000)
    return pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

function formatDayEnd(endSec, startSec) {
    var base = parseInt(endSec, 10) || 0
    if (!base) return formatDayStart(startSec) + " → running"
    var d = new Date(base * 1000)
    return formatDayStart(startSec) + " → " + pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

// "HH:MM – HH:MM" for a closed session that had pauses, with a pause tick.
function formatDaySpan(startSec, endSec, pausedSec) {
    var base = parseInt(endSec, 10) || 0
    if (!base) return formatDayStart(startSec) + " → running"
    var d = new Date(base * 1000)
    var out = formatDayStart(startSec) + " → " + pad2(d.getHours()) + ":" + pad2(d.getMinutes())
    return pausedSec > 0 ? out + " (paused)" : out
}

function tagColor(name, index) {
    var palette = [
        "#89b4fa", "#a6e3a1", "#f9e2af", "#f38ba8",
        "#cba6f7", "#94e2d5", "#fab387", "#74c7ec"
    ]
    if (index !== undefined && index >= 0) return palette[index % palette.length]
    var hash = 0
    for (var i = 0; i < name.length; i++) hash = (hash * 31 + name.charCodeAt(i)) >>> 0
    return palette[hash % palette.length]
}

function taskColor(i) {
    return tagColor("", i)
}

function shortTask(name, max) {
    var s = String(name || "")
    max = max || 22
    return s.length > max ? s.slice(0, max - 1) + "…" : s
}

// "Mon 16"-style label for a day-start epoch (local time).
function dayLabel(startSec) {
    var names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    var d = new Date(parseInt(startSec, 10) * 1000)
    return names[d.getDay()] + " " + d.getDate()
}

// Draw a per-task breakdown as a vertical bar chart: column height is
// proportional to each task's share of the period total. Colors match the
// per-day timeline above (same task → same color).
function drawTaskBars(ctx, tasks, total, sessions, width, height) {
    ctx.reset()
    if (!tasks || tasks.length === 0 || !total) return
    var n = tasks.length

    var colorIndex = {}
    var idx = 0
    for (var i = 0; i < (sessions || []).length; i++) {
        if (!(sessions[i].task in colorIndex)) colorIndex[sessions[i].task] = idx++
    }

    var padX = 8
    var topSpace = 16
    var bottomSpace = 18
    var baseY = height - bottomSpace
    var hMax = Math.max(10, height - topSpace - bottomSpace)
    var colW = (width - padX * 2) / n

    ctx.font = "9px monospace"
    ctx.textAlign = "center"

    for (var k = 0; k < n; k++) {
        var t = tasks[k]
        var frac = total > 0 ? t.seconds / total : 0
        var barW = Math.max(2, colW - 4)
        var barH = Math.max(2, Math.round(frac * hMax))
        var x = padX + colW * k
        var cx = x + colW / 2
        var c = taskColor(colorIndex[t.name] !== undefined ? colorIndex[t.name] : k)

        ctx.fillStyle = c
        ctx.fillRect(x + (colW - barW) / 2, baseY - barH, barW, barH)

        // time share on top of the bar
        ctx.fillStyle = "rgba(255,255,255,0.75)"
        ctx.fillText(minLabel(t.seconds), cx, baseY - barH - 4)

        // task name under the bar, elided to column width
        var maxChar = Math.max(3, Math.floor(colW / 5.4))
        var label = shortTask(t.name, maxChar)
        ctx.fillStyle = "rgba(255,255,255,0.45)"
        ctx.fillText(label, cx, baseY + 12)
    }
}

// Draw the period's per-day totals as a vertical bar chart: one column per
// day, height proportional to that day's tracked time (relative to the most
// productive day), day name below. days = [{ start: epochMidnight, seconds }].
function drawDayBars(ctx, days, width, height) {
    ctx.reset()
    if (!days || days.length === 0) return
    var maxSec = 0
    for (var i = 0; i < days.length; i++) maxSec = Math.max(maxSec, days[i].seconds || 0)
    if (maxSec <= 0) return
    var n = days.length

    var padX = 8
    var topSpace = 16
    var bottomSpace = 18
    var baseY = height - bottomSpace
    var hMax = Math.max(10, height - topSpace - bottomSpace)
    var colW = (width - padX * 2) / n

    ctx.font = "9px monospace"
    ctx.textAlign = "center"

    for (var k = 0; k < n; k++) {
        var d = days[k]
        var barW = Math.max(2, colW - 4)
        var barH = Math.max(2, Math.round((d.seconds / maxSec) * hMax))
        var x = padX + colW * k
        var cx = x + colW / 2

        ctx.fillStyle = "#89b4fa"
        ctx.fillRect(x + (colW - barW) / 2, baseY - barH, barW, barH)

        if (barH > 18) {
            ctx.fillStyle = "rgba(255,255,255,0.75)"
            ctx.fillText(minLabel(d.seconds), cx, baseY - barH - 4)
        }

        // day name under the bar, elided to column width
        ctx.fillStyle = "rgba(255,255,255,0.45)"
        ctx.fillText(shortTask(dayLabel(d.start), Math.max(3, Math.floor(colW / 5.4))), cx, baseY + 12)
    }
}
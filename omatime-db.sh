#!/usr/bin/env bash

# omatime-db.sh — sqlite3 backend for the omaTime plugin.
# Data lives at $OMATIME_DB (default ~/.local/share/omatime/omatime.db).
#
# Commands:
#   init                        create schema
#   current                     running session as JSON (or null)
#   start <task> [note] [tags]  stop any running session, start a new one
#   stop                        close the running session (end=now)
#   pause                       pause the running session (start of pause)
#   resume                      end the pause, folding its time into paused_sec
#   note <text>                 set note on running session
#   tags <json>                 set tags on running session
#   tasks [query]               distinct task names (recency-first)
#   taglist [query]             distinct tags
#   range <day|week|month>      sessions + per-task + per-day totals for period
#   today                       alias for range day (sessions + task totals)
#   history [n]                 recent closed sessions (default 20)
#   get <key> [default]         global setting value (JSON string) or default
#   set <key> <value>           upsert a global setting

set -euo pipefail

DB="${OMATIME_DB:-$HOME/.local/share/omatime/omatime.db}"
DB_DIR="$(dirname "$DB")"
mkdir -p "$DB_DIR"
# The database holds private task names and session notes: lock the directory
# to the owner (0700) and the file to mode 0600, regardless of umask. Existing
# files get normalized too, so a DB first created with a loose umask is fixed.
chmod 700 "$DB_DIR"
if [[ ! -e "$DB" ]]; then
  : >"$DB"
fi
chmod 600 "$DB"

init_db() {
  sqlite3 "$DB" <<'SQL'
CREATE TABLE IF NOT EXISTS sessions (
  id    INTEGER PRIMARY KEY AUTOINCREMENT,
  task  TEXT NOT NULL,
  note  TEXT NOT NULL DEFAULT '',
  tags  TEXT NOT NULL DEFAULT '[]',
  start INTEGER NOT NULL,
  end   INTEGER,
  paused_sec INTEGER NOT NULL DEFAULT 0,
  paused_at  INTEGER
);
CREATE INDEX IF NOT EXISTS idx_sessions_start ON sessions(start);
CREATE TABLE IF NOT EXISTS tasks (
  name       TEXT PRIMARY KEY,
  last_used  INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS tags (
  name       TEXT PRIMARY KEY,
  last_used  INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS settings (
  key    TEXT PRIMARY KEY,
  value  TEXT NOT NULL
);
SQL
  # schema migration: older DBs lack the pause columns
  local has_paused_sec has_paused_at
  has_paused_sec=$(sqlite3 "$DB" "SELECT COUNT(*) FROM pragma_table_info('sessions') WHERE name='paused_sec';")
  if [[ "$has_paused_sec" == "0" ]]; then sqlite3 "$DB" "ALTER TABLE sessions ADD COLUMN paused_sec INTEGER NOT NULL DEFAULT 0;"; fi
  has_paused_at=$(sqlite3 "$DB" "SELECT COUNT(*) FROM pragma_table_info('sessions') WHERE name='paused_at';")
  if [[ "$has_paused_at" == "0" ]]; then sqlite3 "$DB" "ALTER TABLE sessions ADD COLUMN paused_at INTEGER;"; fi
  return 0
}

now() { date +%s; }

c() { local s="$1"; printf '%s' "${s//\'/\'\'}"; }

upsert_tasks_and_tags() {
  local task="$1" tags="$2" ts="$3"
  sqlite3 "$DB" "
    INSERT OR REPLACE INTO tasks (name,last_used) VALUES ('$(c "$task")',$ts);
    INSERT OR IGNORE INTO tags (name,last_used)
      SELECT value, $ts FROM json_each('$(c "$tags")');
    UPDATE tags SET last_used = MAX(last_used, $ts)
      WHERE name IN (SELECT value FROM json_each('$(c "$tags")'));"
}

current() {
  init_db
  local out
  out=$(sqlite3 -json "$DB" \
    "SELECT id,task,note,tags,start,paused_sec,paused_at FROM sessions WHERE end IS NULL ORDER BY id DESC LIMIT 1;" \
    | jq -c 'if length > 0 then (.[0] | .paused_sec //= 0 | .) else null end')
  [[ -n $out ]] || out=null
  printf '%s\n' "$out"
}

# Fold any active pause into paused_sec, then close the running session.
close_running() {
  local ts="$1"
  sqlite3 "$DB" "
    UPDATE sessions SET
      paused_sec = paused_sec + CASE WHEN paused_at IS NOT NULL THEN $ts - paused_at ELSE 0 END,
      paused_at  = NULL,
      end        = $ts
    WHERE end IS NULL;"
}

start() {
  init_db
  local task="${1:-Untitled}" note="${2:-}" tags="${3:-[]}"
  local ts; ts=$(date +%s)
  close_running "$ts"
  sqlite3 "$DB" "
    INSERT INTO sessions (task,note,tags,start)
    VALUES ('$(c "$task")','$(c "$note")','$(c "$tags")',$ts);"
  upsert_tasks_and_tags "$task" "$tags" "$ts"
  current
}

stop() {
  init_db
  local ts; ts=$(date +%s)
  close_running "$ts"
  current
}

pause() {
  init_db
  local ts; ts=$(date +%s)
  sqlite3 "$DB" "UPDATE sessions SET paused_at = COALESCE(paused_at, $ts) WHERE end IS NULL AND paused_at IS NULL;"
  current
}

resume() {
  init_db
  local ts; ts=$(date +%s)
  sqlite3 "$DB" "
    UPDATE sessions SET
      paused_sec = paused_sec + ($ts - paused_at),
      paused_at  = NULL
    WHERE end IS NULL AND paused_at IS NOT NULL;"
  current
}

note() {
  init_db
  sqlite3 "$DB" "UPDATE sessions SET note='$(c "${1:-}")' WHERE end IS NULL;"
  current
}

tags() {
  init_db
  local json="${1:-[]}" ts; ts=$(date +%s)
  sqlite3 "$DB" "UPDATE sessions SET tags='$(c "$json")' WHERE end IS NULL;"
  sqlite3 "$DB" "
    INSERT OR IGNORE INTO tags (name,last_used)
      SELECT value, $ts FROM json_each('$(c "$json")');
    UPDATE tags SET last_used = MAX(last_used, $ts)
      WHERE name IN (SELECT value FROM json_each('$(c "$json")'));"
  current
}

tasks() {
  init_db
  local q="${1:-}"
  if [[ -n $q ]]; then
    sqlite3 -json "$DB" \
      "SELECT name FROM tasks WHERE name LIKE '%$(c "$q")%' ORDER BY last_used DESC LIMIT 15;" \
      | jq -c '[.[].name]'
  else
    sqlite3 -json "$DB" \
      "SELECT name FROM tasks ORDER BY last_used DESC LIMIT 15;" \
      | jq -c '[.[].name]'
  fi
}

taglist() {
  init_db
  local q="${1:-}"
  if [[ -n $q ]]; then
    sqlite3 -json "$DB" \
      "SELECT name FROM tags WHERE name LIKE '%$(c "$q")%' ORDER BY last_used DESC LIMIT 15;" \
      | jq -c '[.[].name]'
  else
    sqlite3 -json "$DB" \
      "SELECT name FROM tags ORDER BY last_used DESC LIMIT 15;" \
      | jq -c '[.[].name]'
  fi
}

today() {
  range "day"
}

# range <day|week|month> — sessions, per-task totals and per-day totals over
# a period. Returns { title, start, end, total, sessions[], tasks[], days[] }.
# - day  : local midnight -> now (this calendar day)
# - week : local Monday midnight -> +7 days
# - month: 1st midnight -> +n calendar days
range() {
  init_db
  local scope="${1:-day}" now_sec anchor start end title
  now_sec=$(now)
  anchor=$(date -d "$(date +%F)" +%s)
  case $scope in
    week)
      local dow; dow=$(date +%u)   # 1=Mon .. 7=Sun
      start=$(( anchor - (dow - 1) * 86400 ))
      end=$(( start + 7 * 86400 ))
      title="THIS WEEK"
      ;;
    month)
      start=$(date -d "$(date +%Y-%m-01)" +%s)
      end=$(date -d "$(date +%Y-%m-01) +1 month" +%s)
      title="THIS MONTH"
      ;;
    *) # day
      start=$anchor
      end=$(( start + 86400 ))
      title="TODAY"
      ;;
  esac
  sqlite3 -json "$DB" "
    SELECT id,task,note,tags,start,
           CASE WHEN end IS NULL THEN 0 ELSE 1 END AS closed,
           CASE WHEN end IS NULL THEN $now_sec ELSE end END AS end,
           paused_sec,
           paused_at
    FROM sessions WHERE start >= $start AND start < $end ORDER BY start DESC;" \
  | jq -c --argjson now "$now_sec" --argjson start "$start" --argjson end "$end" --arg title "$title" '
      def active: (if .closed == 1 then (.end - .start)
                   elif .paused_at != null and .paused_at > 0 then (.paused_at - .start)
                   else (.end - .start) end) - (.paused_sec // 0);
      def sec: (active | if . < 0 then 0 else . end);
      { title: $title,
        start: $start,
        end: $end,
        sessions: (map(. + { sec: sec })),
        tasks:  (group_by(.task) | map({ name: .[0].task,
                                        seconds: (map(sec) | add) })
                 | sort_by(-.seconds)),
        total:  ((map(sec) | add) // 0),
        days:   (map({ start: ((.start - $start) / 86400 | floor) * 86400 + $start,
                      seconds: sec })
                 | group_by(.start)
                 | map({ start: .[0].start, seconds: (map(.seconds) | add) })
                 | sort_by(.start)) }'
}

history() {
  init_db
  local n="${2:-20}"
  sqlite3 -json "$DB" "
    SELECT id, task, note, tags, start, end, paused_sec,
           (CASE WHEN end IS NOT NULL THEN (end - start) - COALESCE(paused_sec, 0) ELSE 0 END) AS active
    FROM sessions WHERE end IS NOT NULL ORDER BY id DESC LIMIT $((n));" | jq -c .
}

get() {
  init_db
  local key="${1:-}" def="${2:-}" out
  [[ -n $key ]] || { echo "null"; return; }
  out=$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='$(c "$key")';")
  if [[ -n $out ]]; then
    printf '%s\n' "$out" | jq -R .
  elif [[ -n $def ]]; then
    printf '%s\n' "$def" | jq -R .
  else
    echo "null"
  fi
}

set() {
  init_db
  local key="${1:-}" value="${2:-}"
  [[ -n $key ]] || return
  sqlite3 "$DB" "INSERT INTO settings (key,value) VALUES ('$(c "$key")','$(c "$value")')
    ON CONFLICT(key) DO UPDATE SET value='$(c "$value")';"
  get "$key"
}

cmd="${1:-}"
case $cmd in
  init) init_db ;;
  current) current ;;
  start) start "${2:-}" "${3:-}" "${4:-[]}" ;;
  stop) stop ;;
  pause) pause ;;
  resume) resume ;;
  note) note "${2:-}" ;;
  tags) tags "${2:-}" ;;
  tasks) tasks "${2:-}" ;;
  taglist) taglist "${2:-}" ;;
  today) range "day" ;;
  range) range "${2:-day}" ;;
  history) history "$@" ;;
  get) get "${2:-}" "${3:-}" ;;
  set) set "${2:-}" "${3:-}" ;;
  *)
    echo "unknown command: $cmd" >&2
    exit 2 ;;
esac
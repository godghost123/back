#!/bin/bash
# arraybackup - restore.sh
# Asynchroner Restore-Job (gestartet von ajax.php, niemals vom Scheduler): holt
# eine Datei oder ein Verzeichnis aus einem Snapshot zurueck. Die Parameter
# kommen ueber Umgebungsvariablen, NICHT ueber $argv (register_argc_argv kann in
# der php.ini abgeschaltet sein - $argv waere undefiniert, siehe die
# write_json-Panne in 2026.11.06.003):
#   AB_SRC    absoluter Quellpfad innerhalb des Backup-Ziels (runs/<id>/...)
#   AB_DEST   absoluter Zielpfad (Endpfad des wiederhergestellten Objekts)
#   AB_MODE   overwrite | skip (skip = rsync --ignore-existing)
#   AB_RID    Lauf-ID (nur Anzeige)
#   AB_LABEL  Browser-Pfad der Quelle (nur Anzeige)
# Restore ist additiv by design: NIE rsync --delete - was am Ziel schon existiert,
# darf kein Restore zerstoeren (dafuer ist der Modus "skip" da).
# Status/Fortschritt laufen exakt wie in engine.sh (restore.json + progress-log
# mit rsync --info=progress2), damit die WebUI denselben Balken-Code nutzt.
set -u
set -o pipefail

PLUGIN="arraybackup"
CONF_DIR="/boot/config/plugins/${PLUGIN}"
LOG_DIR="${CONF_DIR}/logs"
RUN_DIR="/var/run/${PLUGIN}"
PID_FILE="${RUN_DIR}/restore.pid"
STATUS_FILE="${RUN_DIR}/restore.json"
STOP_FILE="${RUN_DIR}/restore.stop.flag"
PROG_FILE="${RUN_DIR}/restore.progress.log"
ERR_FILE="${RUN_DIR}/restore.err"
LOCK_FILE="${RUN_DIR}/restore.lock"

SRC="${AB_SRC:-}"
DEST="${AB_DEST:-}"
MODE="${AB_MODE:-overwrite}"
RID="${AB_RID:-}"
LABEL="${AB_LABEL:-}"
START_EPOCH=$(date +%s)
LAST_PCT=""; LAST_RATE=""; LAST_ETA=""; STOP_SEEN=""

log() { echo "[$(date '+%F %T')] $*"; }

syslog_err() {
  # busybox-kompatibel halten (wie engine.sh)
  command -v logger >/dev/null 2>&1 || return 0
  logger -t arraybackup "$*" 2>/dev/null || logger "$*" 2>/dev/null
  return 0
}

# json_escape <string> -> gueltiges JSON-String-Literal (identisch zu engine.sh:
# stdin statt $argv, ungueltiges UTF-8 wird durch json_encode ersetzt).
json_escape() {
  local s="$1" out="" c i
  if command -v php >/dev/null 2>&1; then
    out=$(printf '%s' "$s" | php -r '$s = stream_get_contents(STDIN); $j = json_encode((string)$s, 2097152|256); if ($j === false) exit(1); printf("%s", $j);' 2>/dev/null)
    [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  fi
  for (( i=0; i<${#s}; i++ )); do
    c=${s:i:1}
    case "$c" in
      \\) out+='\\' ;;
      '"') out+='\"' ;;
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      *) [[ $c == [[:cntrl:]] ]] || out+="$c" ;;
    esac
  done
  printf '"%s"' "$out"
}

# write_json <file> <body> - zwei Pfade wie in engine.sh: php (validiert +
# canonicalisiert) und ein purer bash-Fallback, falls der php-Subprozess auf
# diesem Server unbrauchbar ist. Ohne Fallback haette ein kaputtes php CLI auch
# jeden Restore-Status blockiert.
write_json() {
  local f="$1"; shift
  local body="$*"
  local rc=0 err="" t="${f}.tmp" dir n
  err=$(printf '%s' "$body" | AB_FILE="$f" php -r '
    $f    = getenv("AB_FILE");
    $body = stream_get_contents(STDIN);
    $doc  = json_decode("{" . $body . "}", true);
    if (!is_array($doc)) { fwrite(STDERR, "arraybackup: write_json got invalid object body\n"); exit 1; }
    $t = $f . ".tmp";
    if (file_put_contents($t, json_encode($doc, 64) . "\n") === false) {
      fwrite(STDERR, "arraybackup: write_json could not write " . $t . "\n"); exit 1;
    }
    if (!rename($t, $f)) {
      fwrite(STDERR, "arraybackup: write_json could not rename " . $t . " -> " . $f . "\n"); exit 1;
    }
    exit 0;
  ' 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  err=$(printf '%s' "$err" | tr '\n\r' '  ' | tr -s ' ')
  log "WARN: php write_json failed for $f (rc=$rc)${err:+ - $err} - trying bash fallback"
  case "$body" in
    (*[[:cntrl:]]*)
      log "ERROR: bash fallback refused $f: body contains control characters"
      return 1 ;;
  esac
  n=$(printf '%s' "${body//\\?/}" | tr -d -c '"' | wc -c)
  [ "$((n % 2))" -eq 0 ] || {
    log "ERROR: bash fallback refused $f: unbalanced quotes in body"
    return 1
  }
  dir=${f%/*}
  [ "$dir" = "$f" ] && dir="."
  mkdir -p -- "$dir" 2>/dev/null
  err=$( { printf '{%s}\n' "$body" >"$t"; } 2>&1 )
  rc=$?
  if [ "$rc" -ne 0 ]; then
    log "ERROR: could not write JSON: $f (rc=$rc)"
    rm -f -- "$t" 2>/dev/null
    return 1
  fi
  mv -f -- "$t" "$f" 2>/dev/null || { rm -f -- "$t" 2>/dev/null; return 1; }
  return 0
}

# write_status <state> [errmsg] - restore.json fuer die WebUI. Fortschritts-
# zeilen werden wie in engine.sh per Token-Form gefunden (rsync-Feldpositionen
# sind version/locale-abhaengig), 0%-Platzzeilen verworfen, letzte gute Werte
# bleiben erhalten ("Fortschrittsanzeige weg" war ein alter engine-Bug).
write_status() {
  local state="$1" errmsg="${2:-}"
  local now pct rate eta last
  now=$(date '+%F %T')
  pct="$LAST_PCT"; rate="$LAST_RATE"; eta="$LAST_ETA"
  if [ -f "$PROG_FILE" ]; then
    last=$(tr '\r' '\n' < "$PROG_FILE" 2>/dev/null | grep -E '[0-9]+%([[:space:]]|$)' | grep -E '([1-9][0-9]*([.,][0-9]+)?%|[1-9][0-9]*([.,][0-9]+)?[[:space:]]*(kB|MB|GB|TB|B)/s)' | tail -n1)
    pct=$(printf '%s' "$last"  | grep -oE '[0-9]+([.,][0-9]+)?%' | head -n1 | tr -d '%' | tr ',' '.')
    rate=$(printf '%s' "$last" | grep -oE '[0-9]+([.,][0-9]+)?[[:space:]]*(kB|MB|GB|TB|B)/s' | head -n1)
    eta=$(printf '%s' "$last"  | grep -oE '[0-9]+:[0-9]{2}(:[0-9]{2})?' | head -n1)
    if [ -n "$pct$rate$eta" ]; then
      LAST_PCT="$pct"; LAST_RATE="$rate"; LAST_ETA="$eta"
    else
      pct="$LAST_PCT"; rate="$LAST_RATE"; eta="$LAST_ETA"
    fi
  fi
  # finished transfers freeze a stale rate/eta - drop them (engine lesson)
  if [ "$state" != "running" ]; then rate=""; eta=""; pct=""; fi
  local errjson="" errj=""
  if [ -n "$errmsg" ]; then
    errj=$(json_escape "$(printf '%s' "$errmsg" | tr '\n\r' '  ')")
    [ -n "$errj" ] && errjson="\"error\":${errj},"
  fi
  # RID/state/mode are engine tokens, the rest goes through json_escape
  write_json "$STATUS_FILE" "\"state\":\"${state}\",\"run_id\":\"${RID}\",\"updated\":\"${now}\",\"elapsed\":$(( $(date +%s) - START_EPOCH )),${errjson}\"label\":$(json_escape "$LABEL"),\"dest\":$(json_escape "$DEST"),\"mode\":\"${MODE}\",\"progress\":{\"pct\":\"${pct}\",\"rate\":\"${rate}\",\"eta\":\"${eta}\"}"
}

main() {
  mkdir -p "$RUN_DIR" "$LOG_DIR"

  # exactly one restore at a time. This lock is the second wall: ajax.php
  # already refuses restore-during-backup and backup-during-restore, but a
  # direct console start must not race either.
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "a restore is already running - aborting"
    syslog_err "arraybackup restore: start refused (another restore is running)"
    exit 1
  fi
  echo $$ > "$PID_FILE"
  rm -f "$STOP_FILE" "$ERR_FILE"
  : > "$PROG_FILE"

  # restore.log lives on the flash stick -> same 1 MB cap as engine logs
  if [ -f "$LOG_DIR/restore.log" ] &&
     [ "$(stat -c%s -- "$LOG_DIR/restore.log" 2>/dev/null || wc -c <"$LOG_DIR/restore.log")" -gt 1048576 ]; then
    tail -c 524288 -- "$LOG_DIR/restore.log" >"$LOG_DIR/restore.log.1" 2>/dev/null && mv -f -- "$LOG_DIR/restore.log.1" "$LOG_DIR/restore.log"
  fi

  if [ -z "$SRC" ] || [ -z "$DEST" ]; then
    write_status failed "missing AB_SRC/AB_DEST - restore must be started from the WebUI"
    rm -f "$PID_FILE"; exit 1
  fi
  if [ ! -e "$SRC" ]; then
    write_status failed "source vanished before start: $SRC"
    syslog_err "arraybackup restore: source vanished: $SRC"
    rm -f "$PID_FILE"; exit 1
  fi
  case "$MODE" in overwrite|skip) ;; *) MODE="overwrite" ;; esac

  # rsync semantics: a trailing slash on a DIRECTORY copies its CONTENTS into
  # DEST, so DEST is the final restored path for files and folders alike.
  local r_src="$SRC" r_dest="$DEST"
  if [ -d "$SRC" ]; then
    r_src="$SRC/"
    if [ -e "$DEST" ] && [ ! -d "$DEST" ]; then
      write_status failed "destination exists and is not a directory: $DEST"
      rm -f "$PID_FILE"; exit 1
    fi
  else
    if [ -d "$DEST" ]; then r_dest="$DEST/$(basename "$SRC")"; fi
  fi
  if ! mkdir -p -- "$(dirname "$r_dest")" 2>/dev/null; then
    write_status failed "cannot create destination parent: $(dirname "$r_dest")"
    rm -f "$PID_FILE"; exit 1
  fi

  # NO --delete ever (additive restore); --partial-dir keeps interrupted files
  # out of the restored tree (same lesson as engine.sh)
  local args=(-aHAX --numeric-ids --stats --info=progress2 --partial-dir=".ab-restore-partial")
  [ "$MODE" = "skip" ] && args+=(--ignore-existing)

  log "restore started: $SRC -> $r_dest (mode=$MODE run=$RID)"
  nice -n 10 rsync "${args[@]}" -- "$r_src" "$r_dest" >"$PROG_FILE" 2>"$ERR_FILE" &
  local RS_PID=$! rc=0 state err=""
  while kill -0 "$RS_PID" 2>/dev/null; do
    write_status "running"
    if [ -f "$STOP_FILE" ] && [ -z "$STOP_SEEN" ]; then
      STOP_SEEN=1
      log "stop requested - terminating rsync (pid $RS_PID)"
      pkill -P "$RS_PID" 2>/dev/null
      kill -TERM "$RS_PID" 2>/dev/null
    fi
    sleep 2
  done
  wait "$RS_PID"; rc=$?

  if [ -f "$STOP_FILE" ]; then
    state="aborted"
  elif [ "$rc" -eq 0 ] || [ "$rc" -eq 24 ]; then
    state="success"
  else
    state="failed"
  fi
  if [ "$state" = "failed" ] && [ -f "$ERR_FILE" ]; then
    err=$(tail -c 400 -- "$ERR_FILE" | tr '\n\r' '  ')
  fi
  write_status "$state" "$err"
  echo "$RID restore-$state src=$SRC dest=$DEST mode=$MODE exit=$rc" >> "$LOG_DIR/history.log"
  log "restore finished: state=$state exit=$rc dest=$r_dest"
  [ "$state" != "success" ] && syslog_err "arraybackup restore $state: $SRC -> $DEST (rsync exit $rc)${err:+ - $err}"
  rm -f "$PID_FILE"
  [ "$state" = "success" ]
}

main

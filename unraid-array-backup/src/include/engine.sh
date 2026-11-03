#!/bin/bash
# arraybackup - engine.sh
# Paralleles Datei-Backup aller UNRAID-Datendisks (/mnt/diskN) auf ein schnelles
# lokales Ziel. Jeder Lauf erzaehlt einen vollstaendigen Snapshot des Arrays
# (rsync --link-dest, harte Links = space-effizient). Paritaet ist unter /mnt
# nicht gemountet und wird automatisch uebersprungen.
set -u

PLUGIN="arraybackup"
CONF_DIR="/boot/config/plugins/${PLUGIN}"
CONF_FILE="${CONF_DIR}/config.json"
LOG_DIR="${CONF_DIR}/logs"
RUN_DIR="/var/run/${PLUGIN}"
LOCK_FILE="${RUN_DIR}/engine.lock"
PID_FILE="${RUN_DIR}/engine.pid"
STATUS_FILE="${RUN_DIR}/status.json"
STOP_FILE="${RUN_DIR}/stop.flag"
PROG_DIR="${RUN_DIR}/progress"
STATS_DIR="${RUN_DIR}/stats"

DISKS=()
PIDS=()
RUN_ID=""
CFG_TARGET="/mnt/backup"
CFG_RETENTION=14
CFG_MINFREE=500
CFG_MAXJOBS=0
CFG_BWLIMIT=0
CFG_DRYRUN=0
CFG_RESUME=1
CFG_EXCLUDES=""

log() { echo "[$(date '+%F %T')] $*"; }

# Fehler zusaetzlich ins syslog (journalctl -t arraybackup / Syslog-Server),
# damit die WebUI und root die Ursache sehen, nicht nur engine.log auf Flash.
syslog_err() {
  # busybox-kompatibel halten: kein '--', kein -p mit Punkt-Namen erzwingen
  command -v logger >/dev/null 2>&1 || return 0
  logger -t arraybackup "$*" 2>/dev/null || logger "$*" 2>/dev/null
  return 0
}

die() {
  log "ERROR: $*"
  syslog_err "FATAL: $*"
  write_status "failed" "${RUN_ID}" "$*"
  exit 1
}

load_config() {
  [ -f "$CONF_FILE" ] || die "config file missing: $CONF_FILE"
  eval "$(php -r '
    $c = json_decode(file_get_contents($argv[1]), true) ?: [];
    $d = array("target"=>"/mnt/backup","retention_runs"=>14,"retention_min_free_gb"=>500,
               "max_jobs"=>0,"bwlimit_kbps"=>0,"dry_run"=>false,"resume_aborted"=>true,"exclude_file"=>"");
    $c += $d;
    printf("CFG_TARGET=%s\n",   escapeshellarg($c["target"]));
    printf("CFG_RETENTION=%d\n", max(1, (int)$c["retention_runs"]));
    printf("CFG_MINFREE=%d\n",   max(0, (int)$c["retention_min_free_gb"]));
    printf("CFG_MAXJOBS=%d\n",   max(0, (int)$c["max_jobs"]));
    printf("CFG_BWLIMIT=%d\n",   max(0, (int)$c["bwlimit_kbps"]));
    printf("CFG_DRYRUN=%d\n",    !empty($c["dry_run"]) ? 1 : 0);
    printf("CFG_RESUME=%d\n",    !empty($c["resume_aborted"]) ? 1 : 0);
    printf("CFG_EXCLUDES=%s\n",  escapeshellarg($c["exclude_file"]));
  ' "$CONF_FILE")"
}

write_status() {
  local state="$1" run_id="$2" errmsg="${3:-}"
  local now d djson="" ejson=""
  now=$(date '+%F %T')
  # JSON-Escaping fuer die Fehlermeldung (WebUI zeigt sie im Banner)
  if [ -n "$errmsg" ]; then
    errmsg=$(printf '%s' "$errmsg" | tr '\n\r' '  ' | tr -d '"\\' | cut -c1-500)
    ejson="\"error\":\"${errmsg}\","
  fi
  for d in "${DISKS[@]}"; do
    local name pct="" rate="" eta="" ex="" last
    name=$(basename "$d")
    if [ -f "$PROG_DIR/$name.log" ]; then
      # --info=progress2: altes rsync "12.34%  123.45MB/s  0:10:23 (xfr#..)",
      # neueres rsync 3.2.3+ "185.869.340.868  81%  1:00:38  77.80MB/s (xfr#..)"
      # (mit locale-Gruppierungspunkten). Feldpositionen sind also NICHT
      # verlaesslich - wir suchen die Werte selbst (Prozent-/Rate-/Zeit-Token).
      last=$(tr '\r' '\n' < "$PROG_DIR/$name.log" 2>/dev/null | grep -E '[0-9]+%([[:space:]]|$)' | tail -n1)
      pct=$(printf '%s' "$last"  | grep -oE '[0-9]*\.?[0-9]+%' | head -n1 | tr -d '%')
      rate=$(printf '%s' "$last" | grep -oE '[0-9]+([.,][0-9]+)?[[:space:]]*(kB|MB|GB|TB|B)/s' | head -n1)
      eta=$(printf '%s' "$last"  | grep -oE '[0-9]+:[0-9]{2}(:[0-9]{2})?' | head -n1)
    fi
    [ -f "$STATS_DIR/$name.exit" ] && ex=$(cat "$STATS_DIR/$name.exit")
    djson="${djson}\"${name}\":{\"pct\":\"${pct}\",\"rate\":\"${rate}\",\"eta\":\"${eta}\",\"exit\":\"${ex}\"},"
  done
  djson=${djson%,}
  printf '{"state":"%s","run_id":"%s","updated":"%s","dry_run":%s,%s"disks":{%s}}\n' \
    "$state" "$run_id" "$now" "${CFG_DRYRUN}" "$ejson" "$djson" > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"
}

running_count() {
  local n=0 p
  for p in "${PIDS[@]}"; do
    kill -0 "$p" 2>/dev/null && n=$((n+1))
  done
  echo "$n"
}

stop_all() {
  log "stop requested - terminating rsync jobs"
  local p
  for p in "${PIDS[@]}"; do
    pkill -P "$p" 2>/dev/null
    kill -TERM "$p" 2>/dev/null
  done
}

validate() {
  local d rt avail_kb need_kb t
  command -v rsync >/dev/null 2>&1 || die "rsync not found on this system - plugin requires rsync"
  command -v php   >/dev/null 2>&1 || die "php not found on this system - cannot parse config"

  DISKS=()
  for d in /mnt/disk[0-9]*; do
    [ -d "$d" ] && DISKS+=("$d")
  done
  [ ${#DISKS[@]} -gt 0 ] || die "no data disks found under /mnt - is the array started?"

  [ -e "$CFG_TARGET" ] || die "backup target does not exist: $CFG_TARGET (check the path in the plugin settings; mount it first, e.g. via the 'Tools' plugin or an NFS/UDM mount)"
  [ -d "$CFG_TARGET" ] || die "backup target path is not a directory: $CFG_TARGET"
  findmnt -T "$CFG_TARGET" >/dev/null 2>&1 || die "target is not a mount point: $CFG_TARGET"
  if ! findmnt -T "$CFG_TARGET" -o TARGET,FSTYPE,SOURCE 2>/dev/null | grep -qiE 'btrfs|ext[234]|xfs|zfs|ntfs|vfat'; then
    log "note: target filesystem type: $(findmnt -T "$CFG_TARGET" -no FSTYPE 2>/dev/null || echo unknown)"
  fi
  [ -w "$CFG_TARGET" ] || die "backup target is not writable (permissions/share read-only?): $CFG_TARGET"

  rt=$(realpath "$CFG_TARGET")
  case "$rt" in
    /mnt/disk[0-9]*|/mnt/user*|/mnt/share*)
      die "refusing to back up onto the array itself: $rt" ;;
  esac

  t="$CFG_TARGET/.ab_linktest.$$"
  if ! (touch "$t" && ln "$t" "$t.2" 2>/dev/null && rm -f "$t" "$t.2"); then
    rm -f "$t" "$t.2" 2>/dev/null
    die "target filesystem does not support hard links (use ext4/xfs/btrfs)"
  fi

  if [ "$CFG_MINFREE" -gt 0 ]; then
    avail_kb=$(df -Pk "$CFG_TARGET" | awk 'NR==2{print $4}')
    need_kb=$((CFG_MINFREE * 1024 * 1024))
    [ "$avail_kb" -ge "$need_kb" ] || \
      die "not enough free space on $CFG_TARGET: ${avail_kb} KB available, ${need_kb} KB required"
  fi
}

mark_stale_runs() {
  local runs_dir="$CFG_TARGET/runs" r meta
  [ -d "$runs_dir" ] || return 0
  for r in "$runs_dir"/*/; do
    meta="$r.runmeta.json"
    [ -f "$meta" ] || continue
    if grep -q '"state":"running"' "$meta" 2>/dev/null; then
      sed -i 's/"state":"running"/"state":"aborted"/' "$meta"
      log "marked stale run as aborted: $(basename "$r")"
    fi
  done
}

prune() {
  local runs_dir="$CFG_TARGET/runs"
  local -a runs
  mapfile -t runs < <(ls -1 "$runs_dir" 2>/dev/null | sort)
  local kept=0 i r pd avail_kb victim

  for ((i=${#runs[@]}-1; i>=0; i--)); do
    r="${runs[i]}"
    [ -f "$runs_dir/$r/.pinned" ] && continue
    kept=$((kept+1))
    if [ "$kept" -gt "$CFG_RETENTION" ]; then
      rm -rf "$runs_dir/$r"
      for pd in "$CFG_TARGET"/perdisk/*/"$r"; do
        [ -L "$pd" ] && rm -f "$pd"
      done
      log "retention: removed run $r"
    fi
  done

  if [ "$CFG_MINFREE" -gt 0 ]; then
    while :; do
      avail_kb=$(df -Pk "$CFG_TARGET" | awk 'NR==2{print $4}')
      [ "$avail_kb" -ge $((CFG_MINFREE * 1024 * 1024)) ] && break
      victim=""
      for r in "${runs[@]}"; do
        [ -d "$runs_dir/$r" ] || continue
        [ -f "$runs_dir/$r/.pinned" ] && continue
        [ "$r" = "$RUN_ID" ] && continue
        victim="$r"; break
      done
      [ -z "$victim" ] && break
      rm -rf "$runs_dir/$victim"
      for pd in "$CFG_TARGET"/perdisk/*/"$victim"; do
        [ -L "$pd" ] && rm -f "$pd"
      done
      log "disk space guard: removed run $victim"
    done
  fi
}

# Lauf-Verzeichnis finden, das unvollstaendig beendet wurde (State aborted/partial/
# failed in .runmeta.json) oder dessen Meta fehlt (Kill/Crash/Reboot mitten im Lauf).
# So einen Lauf koennen wir wiederverwenden: rsync in dasselbe Ziel-Verzeichnis
# ueberspringt bereits kopierte Dateien -> Fortsetzen in Etappen.
find_resumable_run() {
  local runs_dir="$CFG_TARGET/runs" r meta st
  [ -d "$runs_dir" ] || return 1
  for r in $(ls -1 "$runs_dir" 2>/dev/null | grep -E '^r-' | sort -r); do
    meta="$runs_dir/$r/.runmeta.json"
    if [ ! -f "$meta" ]; then echo "$r"; return 0; fi
    st=$(grep -oE '"state":"[a-z]+"' "$meta" | head -n1 | cut -d'"' -f4)
    case "$st" in
      aborted|partial|failed) echo "$r"; return 0 ;;
    esac
  done
  return 1
}

run_backup() {
  RUN_ID="r-$(date +%Y%m%d-%H%M%S)"
  local runs_dir="$CFG_TARGET/runs"
  local run_root="$runs_dir/$RUN_ID"
  local latest_abs="" started d name dest args ex ec state total_logical=0 total_delta=0 dmeta="" dur
  local prev_started="" rid
  local start_epoch=$(date +%s)

  # Etappen-Fortsetzung: den neuesten abgebrochenen Lauf wiederverwenden statt
  # neu beginnen. rsync prueft dann gegen den bereits gefuellten Stand und
  # uebertraegt nur die fehlenden Dateien. (Dry-Runs betreffen kein Ziel.)
  if [ "$CFG_DRYRUN" -eq 0 ] && [ "$CFG_RESUME" -eq 1 ]; then
    if rid=$(find_resumable_run); then
      RUN_ID="$rid"
      run_root="$runs_dir/$RUN_ID"
      prev_started=$(grep -oE '"started":"[^"]+"' "$run_root/.runmeta.json" 2>/dev/null | head -n1 | cut -d'"' -f4)
      log "resuming interrupted run $RUN_ID - already copied files are skipped"
      syslog_err "resuming interrupted run $RUN_ID (Etappen-Fortsetzung aktiv)"
    fi
  fi

  mkdir -p "$runs_dir"
  [ "$CFG_DRYRUN" -eq 0 ] && mkdir -p "$run_root"

  if [ -L "$CFG_TARGET/latest" ]; then
    latest_abs=$(realpath "$CFG_TARGET/latest" 2>/dev/null || true)
  fi

  started=$(date '+%F %T')
  [ -n "$prev_started" ] && started="$prev_started"
  write_status "running" "$RUN_ID"
  log "run $RUN_ID started (disks: ${#DISKS[@]}, dry_run=$CFG_DRYRUN, link-dest=${latest_abs:-none})"

  PIDS=()
  for d in "${DISKS[@]}"; do
    name=$(basename "$d")
    dest="$run_root/$name"
    # --partial: bereits teilweise uebertragene Dateien nicht verwerfen, damit ein
    # spaeterer (fortgesetzter) Lauf daran anknuepfen kann statt neu zu kopieren.
    args=(-aHAX --numeric-ids --delete --stats --info=progress2 --partial)
    if [ -n "$latest_abs" ] && [ -d "$latest_abs/$name" ]; then
      args+=(--link-dest="$latest_abs/$name")
    fi
    [ -n "$CFG_EXCLUDES" ] && [ -f "$CFG_EXCLUDES" ] && args+=(--exclude-from="$CFG_EXCLUDES")
    [ "$CFG_BWLIMIT" -gt 0 ] && args+=(--bwlimit="$CFG_BWLIMIT")
    [ "$CFG_DRYRUN" -eq 1 ] && args+=(-n)

    ( rsync "${args[@]}" "$d/" "$dest/" >"$PROG_DIR/$name.log" 2>&1; \
      echo $? >"$STATS_DIR/$name.exit" ) &
    PIDS+=($!)

    while [ "$CFG_MAXJOBS" -gt 0 ] && [ "$(running_count)" -ge "$CFG_MAXJOBS" ]; do
      sleep 1
    done
  done

  while :; do
    [ -f "$STOP_FILE" ] && stop_all
    write_status "running" "$RUN_ID"
    [ "$(running_count)" -eq 0 ] && break
    sleep 2
  done
  wait

  state="success"
  local fail_detail=""
  for d in "${DISKS[@]}"; do
    name=$(basename "$d")
    ec=$(cat "$STATS_DIR/$name.exit" 2>/dev/null || echo 1)
    if [ "$ec" != "0" ] && [ "$ec" != "24" ]; then
      state="partial"
      # rsync-Fehlerursache ins syslog ziehen (letzte Fehlerzeilen aus dem Job-Log)
      local errline
      errline=$(tr '\r' '\n' < "$PROG_DIR/$name.log" 2>/dev/null | grep -iE 'rsync error|ERROR|error:' | tail -n3 | tr '\n' ' ')
      [ -n "$errline" ] || errline=$(tr '\r' '\n' < "$PROG_DIR/$name.log" 2>/dev/null | tail -n2 | tr '\n' ' ')
      log "ERROR disk $name: rsync exit=$ec - $errline"
      syslog_err "run $RUN_ID: $name failed (rsync exit=$ec): ${errline:-keine Logausgabe}"
      fail_detail="$fail_detail $name(exit=$ec): ${errline:-rsync exit $ec};"
    fi
  done
  [ -f "$STOP_FILE" ] && state="aborted"

  if [ "$CFG_DRYRUN" -eq 1 ]; then
    write_status "$state" "$RUN_ID" "$fail_detail"
    log "dry run $RUN_ID finished with state=$state (nothing written)"
    [ "$state" != "success" ] && syslog_err "dry run $RUN_ID finished with state=$state"
    return 0
  fi

  for d in "${DISKS[@]}"; do
    name=$(basename "$d")
    local logical delta
    logical=$(du -sb "$run_root/$name" 2>/dev/null | awk '{print $1}')
    delta=$(awk '/^Total transferred file size:/{gsub(/,/,"",$5); print $5}' "$PROG_DIR/$name.log" 2>/dev/null)
    [ -z "$logical" ] && logical=0
    [ -z "$delta" ] && delta=0
    total_logical=$((total_logical + logical))
    total_delta=$((total_delta + delta))
    ec=$(cat "$STATS_DIR/$name.exit" 2>/dev/null || echo 1)
    dmeta="${dmeta}\"${name}\":{\"exit\":${ec},\"logical_bytes\":${logical},\"delta_bytes\":${delta}},"
  done
  dmeta=${dmeta%,}

  printf '{"run_id":"%s","state":"%s","started":"%s","finished":"%s","dry_run":false,"total_logical_bytes":%d,"total_delta_bytes":%d,"disks":{%s}}\n' \
    "$RUN_ID" "$state" "$started" "$(date '+%F %T')" "$total_logical" "$total_delta" "$dmeta" \
    > "$run_root/.runmeta.json"

  if [ "$state" = "success" ]; then
    ln -sfn "runs/$RUN_ID" "$CFG_TARGET/latest"
    for d in "${DISKS[@]}"; do
      name=$(basename "$d")
      mkdir -p "$CFG_TARGET/perdisk/$name"
      ln -sfn "../../runs/$RUN_ID/$name" "$CFG_TARGET/perdisk/$name/$RUN_ID"
    done
    prune
  fi

  dur=$(( $(date +%s) - start_epoch ))
  echo "$RUN_ID $state logical=$total_logical delta=$total_delta duration=${dur}s" >> "$LOG_DIR/history.log"
  write_status "$state" "$RUN_ID" "$fail_detail"
  if [ "$state" != "success" ]; then
    syslog_err "run $RUN_ID finished with state=$state (see $LOG_DIR/engine.log)"$fail_detail
  fi
  log "run $RUN_ID finished: state=$state logical=$total_logical delta=$total_delta duration=${dur}s"
}

main() {
  mkdir -p "$RUN_DIR" "$LOG_DIR"

  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "another backup is already running - aborting"
    syslog_err "start refused: another backup is already running"
    exit 1
  fi
  echo $$ > "$PID_FILE"
  rm -f "$STOP_FILE"
  rm -rf "$PROG_DIR" "$STATS_DIR"; mkdir -p "$PROG_DIR" "$STATS_DIR"

  load_config
  validate
  mark_stale_runs
  run_backup
}

main "$@"

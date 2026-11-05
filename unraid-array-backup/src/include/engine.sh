#!/bin/bash
# arraybackup - engine.sh
# Paralleles Datei-Backup aller UNRAID-Datendisks (/mnt/diskN) auf ein schnelles
# lokales Ziel. Jeder Lauf erzaehlt einen vollstaendigen Snapshot des Arrays
# (rsync --link-dest, harte Links = space-effizient). Paritaet ist unter /mnt
# nicht gemountet und wird automatisch uebersprungen.
set -u
set -o pipefail   # df|awk, du|awk, tr|grep|tail must not hide a failed left side

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

# Staging area for unfinished runs. Must live on the target filesystem so the
# promotion to runs/ is a single atomic rename (see run_backup()).
STAGING_SUBDIR=".ab-staging"

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

# Defaults here MUST stay identical to the ones in src/install.sh and ajax.php
# (load_config), otherwise the effective value of a key depends on which of the
# three happened to write the config last. `resume_aborted` used to be missing
# from install.sh and `exclude_file` was "" here while ajax.php shipped a real
# path -> the bundled excludes.txt was silently ignored until first save.
load_config() {
  [ -f "$CONF_FILE" ] || die "config file missing: $CONF_FILE"
  eval "$(php -r '
    $c = json_decode(file_get_contents($argv[1]), true) ?: [];
    $d = array("target"=>"/mnt/backup","retention_runs"=>14,"retention_min_free_gb"=>500,
               "max_jobs"=>0,"bwlimit_kbps"=>0,"dry_run"=>false,"resume_aborted"=>true,
               "exclude_file"=>"/boot/config/plugins/arraybackup/excludes.txt");
    $c += $d;
    printf("CFG_TARGET=%s\n",   escapeshellarg($c["target"]));
    printf("CFG_RETENTION=%d\n", max(1, (int)$c["retention_runs"]));
    printf("CFG_MINFREE=%d\n",   max(0, (int)$c["retention_min_free_gb"]));
    printf("CFG_MAXJOBS=%d\n",   max(0, (int)$c["max_jobs"]));
    printf("CFG_BWLIMIT=%d\n",   max(0, (int)$c["bwlimit_kbps"]));
    printf("CFG_DRYRUN=%d\n",    !empty($c["dry_run"]) ? 1 : 0);
    printf("CFG_RESUME=%d\n",    !empty($c["resume_aborted"]) ? 1 : 0);
    printf("CFG_EXCLUDES=%s\n",  escapeshellarg((string)$c["exclude_file"]));
  ' "$CONF_FILE")"
}

# ---- JSON helpers -----------------------------------------------------------
# json_escape <string> -> valid JSON string literal (substitutes invalid UTF-8,
# which rsync messages can contain; json_encode would otherwise return false).
json_escape() {
  php -r '$s = $argv[count($argv)-1]; $j = json_encode((string)$s, 2097152|256); if ($j === false) exit(1); printf("%s", $j);' "$1" 2>/dev/null
}

# write_json <file> <body>  - body is a JSON object body ("k":v,... pairs,
# no braces). It is json_decode-d FIRST, so a malformed body can never land in
# status.json / .runmeta.json (it fails here instead), then re-encoded with
# json_encode and moved into place atomically (tmp + rename).
write_json() {
  # Compact output (JSON_UNESCAPED_SLASHES only, NO JSON_PRETTY_PRINT): these
  # files are machine-read, and engine.sh greps .runmeta.json for
  # '"state":"..."' - pretty printing inserted a space after ':' and silently
  # broke those greps (resume detection, mark_stale_runs).
  # Failures are logged loudly: a run must never be promoted without meta
  # just because a write hiccupped (disk full, permissions, php OOM).
  php -r '
    $f    = $argv[1];
    $body = implode(" ", array_slice($argv, 2));
    $doc  = json_decode("{" . $body . "}", true);
    if (!is_array($doc)) { fwrite(STDERR, "arraybackup: write_json got invalid object body\n"); exit 1; }
    $t = $f . ".tmp";
    if (file_put_contents($t, json_encode($doc, 64) . "\n") === false) exit 1;
    exit(rename($t, $f) ? 0 : 1);
  ' "$@" 2>/dev/null || { log "WARN: could not write JSON: $1"; return 1; }
}

# The document is assembled through write_json (json_encode), never printf:
# rsync error messages quote paths and paths carry " [ ] * ' $, so the old
# tr -d '"\' "sanitising" produced invalid JSON, and ajax.php's
# json_decode(...) ?: [] then silently turned every failure into "no status".
write_status() {
  local state="$1" run_id="$2" errmsg="${3:-}"
  local now d name pct rate eta ex last diskjson=""
  now=$(date '+%F %T')
  for d in ${DISKS[@]+"${DISKS[@]}"}; do
    name=$(basename "$d")
    # name is a /mnt/disk[0-9]* leaf, so it is JSON-safe; everything free-form
    # (error text) goes through json_escape instead of being pasted raw.
    pct=""; rate=""; eta=""; ex=""
    if [ -f "$PROG_DIR/$name.log" ]; then
      # --info=progress2 changed layout between rsync versions (old:
      # "12.34% 123.45MB/s 0:10:23", rsync 3.2.3+: "185.869.340.868 81%
      # 1:00:38 77.80MB/s" plus locale digit grouping). Field positions are
      # not stable, so each value is located by token shape instead.
      last=$(tr '\r' '\n' < "$PROG_DIR/$name.log" 2>/dev/null | grep -E '[0-9]+%([[:space:]]|$)' | tail -n1)
      pct=$(printf '%s' "$last"  | grep -oE '[0-9]*\.?[0-9]+%' | head -n1 | tr -d '%')
      rate=$(printf '%s' "$last" | grep -oE '[0-9]+([.,][0-9]+)?[[:space:]]*(kB|MB|GB|TB|B)/s' | head -n1)
      eta=$(printf '%s' "$last"  | grep -oE '[0-9]+:[0-9]{2}(:[0-9]{2})?' | head -n1)
    fi
    if [ -f "$STATS_DIR/$name.exit" ]; then
      ex=$(cat "$STATS_DIR/$name.exit")
      case "$ex" in (*[!0-9]*|'') ex="" ;; esac   # digits only, else drop
    fi
    diskjson="${diskjson}${diskjson:+,}\"${name}\":{\"pct\":\"${pct}\",\"rate\":\"${rate}\",\"eta\":\"${eta}\"${ex:+,\"exit\":${ex}}}"
  done
  # state/run_id and disk names are engine-generated tokens and the progress
  # values come from grep -oE patterns -> quote-free by construction. Only the
  # free-form error text needs escaping, and it goes through json_escape.
  local errjson="" errj=""
  if [ -n "$errmsg" ]; then
    errj=$(json_escape "$(printf '%s' "$errmsg" | tr '\n\r' '  ')")
    [ -n "$errj" ] && errjson="\"error\":${errj},"   # drop (not corrupt) if escape failed
  fi
  write_json "$STATUS_FILE" "\"state\":\"${state}\",\"run_id\":\"${run_id}\",\"updated\":\"${now}\",${errjson}\"dry_run\":$([ "$CFG_DRYRUN" -gt 0 ] && echo true || echo false),\"disks\":{${diskjson}}"
}

running_count() {
  # ${arr[@]+...} form: empty array under `set -u` must not abort the script
  local n=0 p
  for p in ${PIDS[@]+"${PIDS[@]}"}; do
    kill -0 "$p" 2>/dev/null && n=$((n+1))
  done
  echo "$n"
}

stop_all() {
  log "stop requested - terminating rsync jobs"
  local p
  for p in ${PIDS[@]+"${PIDS[@]}"}; do
    pkill -P "$p" 2>/dev/null
    kill -TERM "$p" 2>/dev/null
  done
}

# engine.log/cron.log/history.log live on the flash stick; without a size cap
# they grow unboundedly (every cron tick appends). Keep the newest ~1 MB.
rotate_logs() {
  local f
  for f in "$LOG_DIR/engine.log" "$LOG_DIR/cron.log" "$LOG_DIR/history.log"; do
    [ -f "$f" ] || continue
    if [ "$(stat -c%s -- "$f" 2>/dev/null || wc -c <"$f")" -gt 1048576 ]; then
      tail -c 524288 -- "$f" >"$f.1" 2>/dev/null && mv -f -- "$f.1" "$f"
      log "rotated $(basename "$f") (kept newest 512 KB)"
    fi
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
  # findmnt uses --target=PATH (the "=" form), NOT "-T -- PATH": getopt_long
  # would consume a bare "--" as the VALUE of -T, turning the real path into a
  # positional filter that must equal a mountpoint exactly. That breaks the
  # intended "walk up to the containing filesystem" behaviour and rejects
  # subdirectories of real mounts with "target is not a mount point".
  # The "=" form still protects against targets starting with '-'.
  findmnt --target="$CFG_TARGET" >/dev/null 2>&1 || die "cannot resolve a filesystem for the backup target (not mounted or gone?): $CFG_TARGET"
  if ! findmnt --target="$CFG_TARGET" -o TARGET,FSTYPE,SOURCE 2>/dev/null | grep -qiE 'btrfs|ext[234]|xfs|zfs|ntfs|vfat'; then
    log "note: target filesystem type: $(findmnt --target="$CFG_TARGET" -no FSTYPE 2>/dev/null || echo unknown)"
  fi
  [ -w "$CFG_TARGET" ] || die "backup target is not writable (permissions/share read-only?): $CFG_TARGET"

  rt=$(realpath -- "$CFG_TARGET")
  case "$rt" in
    /mnt/disk[0-9]*|/mnt/user*|/mnt/share*)
      die "refusing to back up onto the array itself: $rt" ;;
  esac

  t="$CFG_TARGET/.ab_linktest.$$"
  if ! (touch -- "$t" && ln -- "$t" "$t.2" 2>/dev/null && rm -f -- "$t" "$t.2"); then
    rm -f -- "$t" "$t.2" 2>/dev/null
    die "target filesystem does not support hard links (use ext4/xfs/btrfs)"
  fi

  if [ "$CFG_MINFREE" -gt 0 ]; then
    # last line, not NR==2: a long source name makes df wrap the entry onto a
    # second line, where NR==2 is not the numbers row anymore
    avail_kb=$(df -Pk -- "$CFG_TARGET" | awk 'END{print $4}')
    case "$avail_kb" in (''|*[!0-9]*) die "could not read free space on $CFG_TARGET (df failed)" ;; esac
    need_kb=$((CFG_MINFREE * 1024 * 1024))
    [ "$avail_kb" -ge "$need_kb" ] || \
      die "not enough free space on $CFG_TARGET: ${avail_kb} KB available, ${need_kb} KB required"
  fi
}

mark_stale_runs() {
  # With staging (task 1) an interrupted run never sits in runs/ with state
  # "running": unfinished work lives in $STAGING_SUBDIR and is found by
  # find_resumable_run. runs/ only ever holds completed (or legacy) runs, but a
  # leftover staged run while resume is switched off must not linger forever.
  local runs_dir="$CFG_TARGET/runs" stage_base="$CFG_TARGET/$STAGING_SUBDIR" r meta
  [ -d "$runs_dir" ] || return 0
  for r in "$runs_dir"/*/; do
    meta="$r.runmeta.json"
    [ -f "$meta" ] || continue
    # [[:space:]] tolerance: older builds wrote pretty-printed meta
    if grep -qE '"state"[[:space:]]*:[[:space:]]*"running"' "$meta" 2>/dev/null; then
      sed -i 's/"state"[[:space:]]*:[[:space:]]*"running"/"state":"aborted"/' "$meta"
      log "marked stale run as aborted: $(basename "$r")"
    fi
  done
}

# r-YYYYMMDD-HHMMSS -> "YYYY-MM-DD HH:MM:SS" (pure bash, no date parsing)
id_ts() {
  local t=${1#r-}
  printf '%s-%s-%s %s:%s:%s' "${t:0:4}" "${t:4:2}" "${t:6:2}" "${t:9:2}" "${t:11:2}" "${t:13:2}"
}

# A runs/ entry without usable .runmeta.json shows as "?" in the WebUI and
# cannot be classified by find_resumable_run. Synthesize a minimal meta from
# history.log (every finished run appends exactly one line there) so the
# table tells the truth again - meta absence used to be permanent and silent.
heal_run_meta() {
  local runs_dir="$CFG_TARGET/runs" r id meta line st lg dl
  [ -d "$runs_dir" ] || return 0
  for r in "$runs_dir"/r-*/; do
    [ -d "$r" ] || continue
    id=$(basename "$r")
    meta="$r.runmeta.json"
    [ -f "$meta" ] && grep -qE '"state"[[:space:]]*:' "$meta" 2>/dev/null && continue
    line=$(grep "^$id " "$LOG_DIR/history.log" 2>/dev/null | tail -n1)
    st="unknown"; lg=0; dl=0
    if [ -n "$line" ]; then
      st=$(echo "$line" | awk '{print $2}')
      lg=$(echo "$line" | sed -n 's/.* logical=\([0-9]*\).*/\1/p')
      dl=$(echo "$line" | sed -n 's/.* delta=\([0-9]*\).*/\1/p')
    fi
    log "run $id has no usable .runmeta.json - healed one from history.log (state=$st)"
    syslog_err "arraybackup: run $id lacked .runmeta.json (WebUI showed '?'), healed from history.log (state=$st)"
    write_json "$meta" "$(printf '"run_id":"%s","state":"%s","started":"%s","finished":"","healed":true,"dry_run":false,"total_logical_bytes":%d,"total_delta_bytes":%d,"disks":{}' \
      "$id" "$st" "$(id_ts "$id")" "${lg:-0}" "${dl:-0}")"
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
      rm -rf -- "$runs_dir/$r"
      for pd in "$CFG_TARGET"/perdisk/*/"$r"; do
        [ -L "$pd" ] && rm -f -- "$pd"
      done
      log "retention: removed run $r"
    fi
  done

  if [ "$CFG_MINFREE" -gt 0 ]; then
    while :; do
      avail_kb=$(df -Pk -- "$CFG_TARGET" | awk 'END{print $4}')
      case "$avail_kb" in (''|*[!0-9]*) break ;; esac
      [ "$avail_kb" -ge $((CFG_MINFREE * 1024 * 1024)) ] && break
      victim=""
      for r in "${runs[@]}"; do
        [ -d "$runs_dir/$r" ] || continue
        [ -f "$runs_dir/$r/.pinned" ] && continue
        [ "$r" = "$RUN_ID" ] && continue
        victim="$r"; break
      done
      [ -z "$victim" ] && break
      rm -rf -- "$runs_dir/$victim"
      for pd in "$CFG_TARGET"/perdisk/*/"$victim"; do
        [ -L "$pd" ] && rm -f -- "$pd"
      done
      log "disk space guard: removed run $victim"
    done
  fi
}

# A run that did not finish is resumable. With staging (task 1) an unfinished
# run lives under $CFG_TARGET/.ab-staging/ and is NEVER visible in runs/, so a
# crash can no longer leave a half-written snapshot in the visible chain. The
# legacy branch (a run already promoted into runs/ whose meta says incomplete)
# is handled so older layouts keep resuming.
# Echoes "<kind>:<run-id>" (kind = stage|runs) or nothing.
find_resumable_run() {
  local runs_dir="$CFG_TARGET/runs"
  local stage_base="$CFG_TARGET/$STAGING_SUBDIR" r meta st
  if [ -d "$stage_base" ]; then
    for r in $(ls -1 "$stage_base" 2>/dev/null | grep -E '^r-' | sort -r); do
      echo "stage:$r"; return 0
    done
  fi
  [ -d "$runs_dir" ] || return 1
  for r in $(ls -1 "$runs_dir" 2>/dev/null | grep -E '^r-' | sort -r); do
    meta="$runs_dir/$r/.runmeta.json"
    if [ ! -f "$meta" ]; then echo "runs:$r"; return 0; fi
    st=$(grep -oE '"state"[[:space:]]*:[[:space:]]*"[a-z]+"' "$meta" | head -n1 | cut -d'"' -f4)
    case "$st" in
      # 'unknown' = meta was healed without a history.log line: treat as
      # unfinished (safer side) - re-running rsync into it is just a verify.
      aborted|partial|failed|unknown) echo "runs:$r"; return 0 ;;
    esac
  done
  return 1
}

run_backup() {
  RUN_ID="r-$(date +%Y%m%d-%H%M%S)"
  local runs_dir="$CFG_TARGET/runs"
  local stage_base="$CFG_TARGET/$STAGING_SUBDIR"
  local stage_root="" latest_abs="" started d name dest args ec state resume="" kind rid
  local total_logical=0 total_delta=0 dmeta="" dur prev_started=""
  local start_epoch=$(date +%s)

  # Resume: reuse the newest staged run instead of starting over. rsync then
  # re-checks the already-filled target and only transfers what is missing, so
  # the first (full) backup can run in several sittings. With resume switched
  # off, leftover staged runs are dead weight - drop them.
  if [ "$CFG_DRYRUN" -eq 0 ]; then
    if [ "$CFG_RESUME" -eq 1 ]; then
      resume=$(find_resumable_run)
    elif [ -d "$stage_base" ]; then
      find -- "$stage_base" -mindepth 1 -maxdepth 1 -type d -name 'r-*' -exec rm -rf -- {} +
      log "resume disabled: dropped leftover staged runs"
    fi
  fi
  if [ -n "$resume" ]; then
    kind=${resume%%:*}; rid=${resume#*:}
    if [ "$kind" = stage ]; then
      stage_root="$stage_base/$rid"
      prev_started=$(grep -oE '"started"[[:space:]]*:[[:space:]]*"[^"]+"' "$stage_root/.runmeta.json" 2>/dev/null | head -n1 | cut -d'"' -f4)
      log "resuming staged run $rid - already copied files are skipped"
    else
      # legacy promoted-but-incomplete run: pull it into staging first so it can
      # never be mistaken for a finished snapshot while we continue it. If the
      # move fails, do NOT keep the id: promoting into the still-existing
      # runs/$rid later would NEST the staged dir inside it (mv into a
      # directory), leaving the stale old run visible. Start fresh instead.
      mkdir -p "$stage_base"
      stage_root="$stage_base/$rid"
      if ! mv "$runs_dir/$rid" "$stage_root"; then
        rmdir -- "$stage_root" 2>/dev/null
        stage_root=""
        log "could not move run $rid into staging (permissions?) - starting a fresh run instead"
      else
        prev_started=$(grep -oE '"started"[[:space:]]*:[[:space:]]*"[^"]+"' "$stage_root/.runmeta.json" 2>/dev/null | head -n1 | cut -d'"' -f4)
        log "resuming interrupted run $rid (moved into staging) - already copied files are skipped"
      fi
    fi
    [ -n "$stage_root" ] && RUN_ID="$rid"
  fi
  [ -n "$stage_root" ] || stage_root="$stage_base/$RUN_ID"

  mkdir -p "$runs_dir" "$stage_base"
  [ "$CFG_DRYRUN" -eq 0 ] && mkdir -p "$stage_root"

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
    dest="$stage_root/$name"
    # --partial-dir keeps an interrupted file OUT of the snapshot (hidden
    # .rsync-partial/) yet lets a resumed run pick it up - with bare --partial a
    # truncated file would sit in the snapshot looking like real data (task 2).
    # --delete-delay (not plain --delete) + the R risk rule clean orphaned
    # .rsync-partial leftovers only AFTER the transfer, so a resumed run can
    # still use them and a promoted snapshot never contains a partial file.
    args=(-aHAX --numeric-ids --delete-delay --stats --info=progress2 --partial-dir=.rsync-partial -f 'R .rsync-partial/')
    if [ -n "$latest_abs" ] && [ -d "$latest_abs/$name" ]; then
      args+=(--link-dest="$latest_abs/$name")
    fi
    [ -n "$CFG_EXCLUDES" ] && [ -f "$CFG_EXCLUDES" ] && args+=(--exclude-from="$CFG_EXCLUDES")
    [ "$CFG_BWLIMIT" -gt 0 ] && args+=(--bwlimit="$CFG_BWLIMIT")
    [ "$CFG_DRYRUN" -eq 1 ] && args+=(-n)

    # Retry transient I/O / protocol / timeout failures (rsync exit 10,11,12,30)
    # up to 3 times with backoff; never retry when a stop was requested or for
    # config/fatal codes (1 usage, 2 protocol, 3 io-select, 4 unsupported). exit
    # 24 (vanished source) is left to the caller as a benign partial (task 4).
    ( set +e
      try=0
      while :; do
        rsync "${args[@]}" "$d/" "$dest/" >"$PROG_DIR/$name.log" 2>&1
        ec=$?
        [ "$ec" -eq 0 ] && break
        [ -f "$STOP_FILE" ] && break
        case "$ec" in
          10|11|12|30)
            if [ "$try" -lt 3 ]; then
              try=$((try+1))
              log "retry $try for $name (rsync exit=$ec)"
              sleep $((2*try)); continue
            fi ;;
        esac
        break
      done
      echo "$ec" >"$STATS_DIR/$name.exit"
    ) &
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
    logical=$(du -sb "$stage_root/$name" 2>/dev/null | awk '{print $1}' || true)
    delta=$(awk '/^Total transferred file size:/{gsub(/,/,"",$5); print $5}' "$PROG_DIR/$name.log" 2>/dev/null || true)
    [ -z "$logical" ] && logical=0
    [ -z "$delta" ] && delta=0
    total_logical=$((total_logical + logical))
    total_delta=$((total_delta + delta))
    ec=$(cat "$STATS_DIR/$name.exit" 2>/dev/null || echo 1)
    dmeta="${dmeta}\"${name}\":{\"exit\":${ec},\"logical_bytes\":${logical},\"delta_bytes\":${delta}},"
  done
  dmeta=${dmeta%,}

  # .runmeta.json holds the disk leaf names only (JSON-safe); composed as raw
  # JSON and validated by json_decode inside write_json. A failure here must
  # never pass silently - the WebUI would show the run as "?" (the WebUI reads
  # ONLY this file), so retry with a minimal meta and shout into the syslog.
  local rmbody
  rmbody=$(printf '"run_id":"%s","state":"%s","started":"%s","finished":"%s","dry_run":false,"total_logical_bytes":%d,"total_delta_bytes":%d,"disks":{%s}' \
    "$RUN_ID" "$state" "$started" "$(date '+%F %T')" "$total_logical" "$total_delta" "${dmeta%,}")
  if ! write_json "$stage_root/.runmeta.json" "$rmbody"; then
    syslog_err "run $RUN_ID: full .runmeta.json write failed (disk full?) - retrying minimal"
    if ! write_json "$stage_root/.runmeta.json" \
      "$(printf '"run_id":"%s","state":"%s","started":"%s","finished":"%s","dry_run":false,"total_logical_bytes":%d,"total_delta_bytes":%d,"disks":{}' \
        "$RUN_ID" "$state" "$started" "$(date '+%F %T')" "$total_logical" "$total_delta")"; then
      syslog_err "run $RUN_ID: .runmeta.json could NOT be written at all (disk full, permissions?) - run state only in engine.log/status.json"
    fi
  fi

  if [ "$state" = "success" ]; then
    # never promote a snapshot whose meta could not be written: the WebUI
    # reads ONLY .runmeta.json, and a meta-less run shows up as "?" and is
    # then mistaken for crashed work by resume detection. Keep it staged
    # (resumable) instead and make the operator fix the real cause.
    if [ ! -s "$stage_root/.runmeta.json" ]; then
      die "run $RUN_ID finished but .runmeta.json is missing/empty (disk full?) - kept in staging, will resume after the cause is fixed"
    fi
    # atomic same-filesystem promote: staged -> visible runs/ (task 1).
    if [ -e "$runs_dir/$RUN_ID" ]; then
      # must not happen (a resumed id either lives in staging or was moved
      # there); if it does, mv would NEST the staged dir inside the old one.
      die "run dir already exists in runs/: $RUN_ID (stale copy?) - refusing to promote, check and remove it manually"
    fi
    if ! mv "$stage_root" "$runs_dir/$RUN_ID"; then
      die "could not move staged run $RUN_ID into runs/ (disk full, permissions, or target not one filesystem?)"
    fi
    ln -sfn "runs/$RUN_ID" "$CFG_TARGET/latest"
    for d in "${DISKS[@]}"; do
      name=$(basename "$d")
      mkdir -p "$CFG_TARGET/perdisk/$name"
      ln -sfn "../../runs/$RUN_ID/$name" "$CFG_TARGET/perdisk/$name/$RUN_ID"
    done
    # drop any abandoned staged leftovers from previous crashed runs
    find -- "$stage_base" -mindepth 1 -maxdepth 1 -type d -name 'r-*' -exec rm -rf -- {} +
    prune
  fi

  dur=$(( $(date +%s) - start_epoch ))
  echo "$RUN_ID $state logical=$total_logical delta=$total_delta duration=${dur}s" >> "$LOG_DIR/history.log"
  write_status "$state" "$RUN_ID" "$fail_detail"
  if [ "$state" != "success" ]; then
    syslog_err "run $RUN_ID finished with state=$state (see $LOG_DIR/engine.log) ${fail_detail}"
  fi
  log "run $RUN_ID finished: state=$state logical=$total_logical delta=$total_delta duration=${dur}s"
}

main() {
  mkdir -p "$RUN_DIR" "$LOG_DIR"
  rotate_logs

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
  heal_run_meta
  run_backup
}

main "$@"

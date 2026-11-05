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
POOLS=()
SOURCES=()
SHARES=()
ORPHANS=()
SHARE_EXC=""
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
# Merged fs/ layout defaults (Kap. 4/5 of plans/vorschlag-cache-pool-backup.md).
# These defaults MUST stay identical to src/install.sh and ajax.php load_config.
CFG_BACKUP_POOLS=1
CFG_POOL_FILTER=""
CFG_SKIP_SHARES=""

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
               "exclude_file"=>"/boot/config/plugins/arraybackup/excludes.txt",
               "backup_pools"=>true,"pool_filter"=>"","skip_shares"=>"");
    $c += $d;
    printf("CFG_TARGET=%s\n",   escapeshellarg($c["target"]));
    printf("CFG_RETENTION=%d\n", max(1, (int)$c["retention_runs"]));
    printf("CFG_MINFREE=%d\n",   max(0, (int)$c["retention_min_free_gb"]));
    printf("CFG_MAXJOBS=%d\n",   max(0, (int)$c["max_jobs"]));
    printf("CFG_BWLIMIT=%d\n",   max(0, (int)$c["bwlimit_kbps"]));
    printf("CFG_DRYRUN=%d\n",    !empty($c["dry_run"]) ? 1 : 0);
    printf("CFG_RESUME=%d\n",    !empty($c["resume_aborted"]) ? 1 : 0);
    printf("CFG_EXCLUDES=%s\n",  escapeshellarg((string)$c["exclude_file"]));
    printf("CFG_BACKUP_POOLS=%d\n", !empty($c["backup_pools"]) ? 1 : 0);
    printf("CFG_POOL_FILTER=%s\n", escapeshellarg((string)$c["pool_filter"]));
    printf("CFG_SKIP_SHARES=%s\n", escapeshellarg((string)$c["skip_shares"]));
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
  for d in ${SOURCES[@]+"${SOURCES[@]}"}; do
    name=$(sanitize_token "$(basename "$d")")
    # disk leaves are JSON-safe by construction; pool mount names got
    # normalized through sanitize_token (spaces/special chars -> _)
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
  # orphan warning surfaced in the WebUI banner (Kap. 4.8: warning only)
  local orjson=""
  if [ ${#ORPHANS[@]} -gt 0 ]; then
    orjson="\"orphan\":$(json_escape "$(printf '%s ' "${ORPHANS[@]}")" 2>/dev/null | tr '\n' ' '),"
  fi
  write_json "$STATUS_FILE" "\"state\":\"${state}\",\"run_id\":\"${run_id}\",\"updated\":\"${now}\",${errjson}${orjson}\"dry_run\":$([ "$CFG_DRYRUN" -gt 0 ] && echo true || echo false),\"sources\":{${diskjson}}"
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

# ---------------------------------------------------------------------------
# Merged fs/-Layout (plans/vorschlag-cache-pool-backup.md): alle Sources
# (Array-Disks + Pools) write into ONE shared target tree runs/<id>/fs/.
# A relative Pfad is therefore storage-location independent: a file moved by
# the mover (cache -> array) keeps its target path and gets hard-linked via
# --link-dest instead of copied again (delta ~ 0). Consequence: --delete per
# Job is impossible in the shared tree (a disk-job would delete foreign
# files) -> deletions happen in sweep_orphans() after ALL transfers, per
# share, as a set difference (find/comm/rm) - NOT via rsync --delete from
# an empty helper source (that would empty the whole share dir).
# ---------------------------------------------------------------------------

# Token for progress/status files and JSON keys. Mount names (diskN) stay
# untouched; user-defined pool names may contain spaces/special chars ->
# normalize them (the old "disk leaf is JSON-safe" assumption in write_status
# must not be relied on for pool names).
sanitize_token() {
  local t="$1"
  printf '%s' "${t//[^A-Za-z0-9._-]/_}"
}

# Pools = every /mnt/* that is neither an Array-disk, a unRAID-internal mount
# nor the Backup-Target itself, and that has a real filesystem. Also feeds
# the Self-Backup-Guard (target may not be a pool mount).
discover_pools() {
  local d rp target_rp
  target_rp=$(realpath -- "$CFG_TARGET" 2>/dev/null || true)
  POOLS=()
  for d in /mnt/*; do
    [ -d "$d" ] || continue
    case "$(basename "$d")" in
      disk[0-9]*|user|recycle|unraid|remotes|.array|.ab-staging) continue ;;
    esac
    rp=$(realpath -- "$d" 2>/dev/null) || continue
    # the target itself is often a pool mount (/mnt/backup) - it must never
    # become a source (that would back up the Backup into itself)
    [ "$rp" = "$target_rp" ] && continue
    findmnt --target="$d" -no FSTYPE 2>/dev/null | grep -qiE 'btrfs|xfs|ext[234]|zfs' || continue
    POOLS+=("$d")
  done
  # optional pool_filter: comma list of mount names, empty = all
  if [ -n "$CFG_POOL_FILTER" ]; then
    local -a keep=()
    for d in ${POOLS[@]+"${POOLS[@]}"}; do
      for rp in ${CFG_POOL_FILTER//,/ }; do
        [ "$(basename "$d")" = "${rp// /}" ] && keep+=("$d") && break
      done
    done
    POOLS=("${keep[@]+"${keep[@]}"}")
  fi
}

# Share decision (per top-level dir, Kap. 4.3 of the plan):
# 1) skip_shares (manual)            -> exclude
# 2) shareUseCache=only|system       -> exclude (secured separately)
#    Key verified on server: docker.cfg contains shareUseCache="only";
#    older installs write share_use -> accept both spellings.
# 3) Array-Realitaets-Check: dir exists on at least one /mnt/diskN -> secure;
#    otherwise it never lands on the array (e.g. Cache -> Backup) -> orphan,
#    warning only, excluded.
cfg_share_use() {
  # echoes "" (unknown) | only | prefer | auto | no ... (lowercase)
  local f="/boot/config/shares/$1.cfg" v=""
  [ -f "$f" ] || return 0
  v=$(grep -oiE 'shareUseCache[[:space:]]*=[[:space:]]*"?[A-Za-z]*"?' "$f" 2>/dev/null | head -n1)
  [ -n "$v" ] || v=$(grep -oiE 'share_use[[:space:]]*=[[:space:]]*"?[A-Za-z]*"?' "$f" 2>/dev/null | head -n1)
  v=${v#*=}
  printf '%s' "${v//[^A-Za-z]/}" | tr 'A-Z' 'a-z'
}

# Build SHARES (covered), ORPHANS (warning) and EXC_ARGS (rsync excludes,
# used by EVERY job AND by the sweep so skipped shares are never deleted).
discover_shares() {
  local s name use d on_array
  SHARES=(); ORPHANS=(); EXC_ARGS=()
  local -A cand=()
  for s in ${SOURCES[@]+"${SOURCES[@]}"}; do
    for name in "$s"/*/; do
      [ -d "$name" ] || continue
      cand["${name##*/}"]=1
    done
  done
  for name in "${!cand[@]}"; do
    case ",${CFG_SKIP_SHARES// /,}," in
      *",$name,"*)
        log "share $name: skipped (skip_shares)"
        EXC_ARGS+=("--exclude=/$name/"); continue ;;
    esac
    use=$(cfg_share_use "$name")
    on_array=0
    for d in "${DISKS[@]}"; do
      [ -d "$d/$name" ] && on_array=1
    done
    if [ "$use" = only ] || [ "$use" = system ]; then
      log "share $name: skipped (shareUseCache=$use, secured separately)"
      EXC_ARGS+=("--exclude=/$name/")
    elif [ "$on_array" -eq 0 ]; then
      ORPHANS+=("$name")
      log "orphan $name: exists only on pool(s), never moved to the array - NOT secured by this run"
      EXC_ARGS+=("--exclude=/$name/")
    else
      SHARES+=("$name")
    fi
  done
}

# Orphan-Sweep per Share after ALL transfers (Kap. 3, decided):
# Union of sources (A) vs. target content (B); B-A deleted via find+comm+rm.
# Guards: only when every expected source is still mounted; never more than
# 50 % of a share's entries (source gone / mount problem -> refuse, the run
# is demoted to partial and stays unstaged); .rsync-partial trees protected
# (resume needs them, they get cleaned only after the transfers).
sweep_orphans() {
  local stage_root="$1" fsroot="$1/fs" s share a_list b_list orphans del tot
  for s in ${SOURCES[@]+"${SOURCES[@]}"}; do
    findmnt --target="$s" >/dev/null 2>&1 || {
      log "sweep skipped: source $s is not mounted anymore (its files would falsely orphan)"
      return 1
    }
  done
  local total_deleted=0
  for share in ${SHARES[@]+"${SHARES[@]}"}; do
    a_list=$(for s in "${SOURCES[@]}"; do
      [ -d "$s/$share" ] && find "$s/$share" -mindepth 1 -name '.rsync-partial*' -prune -o -printf '%P\n' 2>/dev/null
    done | sort -u)
    b_list=$(find "$fsroot/$share" -mindepth 1 -name '.rsync-partial*' -prune -o -printf '%P\n' 2>/dev/null | sort -u)
    orphans=$(comm -13 <(printf '%s\n' "$a_list") <(printf '%s\n' "$b_list") 2>/dev/null)
    tot=$(printf '%s\n' "$b_list" | grep -c . || true)
    del=$(printf '%s\n' "$orphans" | grep -c '[^[:space:]]' || true)
    if [ "${tot:-0}" -gt 0 ] && [ "${del:-0}" -gt $((tot/2)) ]; then
      log "sweep ABORTED for share $share: $del of $tot entries vanished in source - suspicious, no deletions this sweep"
      syslog_err "arraybackup: sweep for $share aborted (too many orphans: $del/$tot)"
      return 1
    fi
    while IFS= read -r a_file; do
      [ -n "$a_file" ] || continue
      rm -rf -- "$fsroot/$share/$a_file"
      total_deleted=$((total_deleted+1))
    done <<< "$orphans"
    find "$fsroot/$share" -mindepth 1 -depth -type d -empty -delete 2>/dev/null
  done
  # partial dirs of completed transfers must not land in the snapshot
  find "$fsroot" -mindepth 2 -type d -name '.rsync-partial*' -exec rm -rf -- {} + 2>/dev/null
  log "sweep done: $total_deleted orphaned entries removed"
  SWEEP_DELETED=$total_deleted
  return 0
}

validate() {
  local d rt avail_kb need_kb t pool_rp
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
  # merged layout: pool detection feeds the Self-Backup-Guard (a pool as
  # target must never become a source) and the source list.
  discover_pools
  if [ "$CFG_BACKUP_POOLS" -eq 0 ]; then POOLS=(); fi
  SOURCES=()
  for d in "${DISKS[@]}"; do SOURCES+=("$d"); done
  for d in ${POOLS[@]+"${POOLS[@]}"}; do SOURCES+=("$d"); done
  for d in /mnt/*; do
    [ -d "$d" ] || continue
    case "$(basename "$d")" in
      disk[0-9]*|user|recycle|unraid|remotes|.array|.ab-staging) continue ;;
    esac
    if [ "$(realpath -- "$d" 2>/dev/null)" = "$rt" ]; then
      log "note: the target $rt is a pool mount - it is NOT used as a source, its content is not covered by this plugin"
      break
    fi
  done
  discover_shares
  [ ${#SHARES[@]} -gt 0 ] || die "no share covered (every top-level dir is pool-only or excluded) - is the array started or are shares misconfigured?"
  log "sources: ${#DISKS[@]} disks + ${#POOLS[@]} pools, ${#SHARES[@]} shares covered, ${#ORPHANS[@]} orphans"

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
    write_json "$meta" "$(printf '"run_id":"%s","state":"%s","started":"%s","finished":"","healed":true,"dry_run":false,"total_logical_bytes":%d,"total_delta_bytes":%d,"disks":{},"sources":{}' \
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
      for pd in "$CFG_TARGET"/perdisk/*/"$r" "$CFG_TARGET"/pershare/*/"$r"; do
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
      for pd in "$CFG_TARGET"/perdisk/*/"$victim" "$CFG_TARGET"/pershare/*/"$victim"; do
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
      # mixed-layout guard (Kap. 10.6 "only migration"): a staged run that was
      # built with the OLD per-disk layout (dirs diskN/, no fs/) must not be
      # continued into the new shared fs tree - the layouts would mix within
      # one run id. Such leftovers simply get dropped and the retention
      # prunes the old visible runs.
      if [ ! -d "$stage_root/fs" ]; then
        log "staged run $rid has the legacy (per-disk) layout - not resumed, dropped; new runs start in the fs/ layout"
        rm -rf -- "$stage_root"
        stage_root=""
      else
        prev_started=$(grep -oE '"started"[[:space:]]*:[[:space:]]*"[^"]+"' "$stage_root/.runmeta.json" 2>/dev/null | head -n1 | cut -d'"' -f4)
        log "resuming staged run $rid - already copied files are skipped"
      fi
    else
      # legacy promoted-but-incomplete run: pull it into staging first so it can
      # never be mistaken for a finished snapshot while we continue it. If the
      # move fails, do NOT keep the id: promoting into the still-existing
      # runs/$rid later would NEST the staged dir inside it (mv into a
      # directory), leaving the stale old run visible. Start fresh instead.
      # a promoted-but-incomplete run of the OLD layout is never resumed into
      # the fs/ tree: leave it in runs/ (it shows up as partial/aborted) and
      # start a fresh run in the new layout; retention cleans the old one.
      if [ -d "$runs_dir/$rid" ] && [ ! -d "$runs_dir/$rid/fs" ]; then
        log "run $rid has the legacy (per-disk) layout - not resumed (stays visible), starting fresh in the fs/ layout"
        resume=""
      else
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
  log "run $RUN_ID started (sources: ${#SOURCES[@]} = ${#DISKS[@]} disks + ${#POOLS[@]} pools, shares: ${#SHARES[@]}, dry_run=$CFG_DRYRUN, link-dest=${latest_abs:-none})"

  PIDS=()
  # Merged layout: every source writes into the SAME fs/ subdir of the staging
  # run -> the relative Pfad of a file is storage-location independent, so a
  # mover-move (cache -> array) between two runs keeps the target path and
  # --link-dest hard-links it instead of re-copying (delta ~ 0).
  # NO --delete here: a job must never remove files that other sources bring
  # in - deletions are done per share by sweep_orphans() after the transfers.
  mkdir -p "$stage_root/fs"
  for d in "${SOURCES[@]}"; do
    name=$(sanitize_token "$(basename "$d")")
    dest="$stage_root/fs"
    args=(-aHAX --numeric-ids --stats --info=progress2 --partial-dir=.rsync-partial -f 'R .rsync-partial/')
    if [ -n "$latest_abs" ] && [ -d "$latest_abs/fs" ]; then
      args+=(--link-dest="$latest_abs/fs")
    fi
    for ex in ${EXC_ARGS[@]+"${EXC_ARGS[@]}"}; do
      args+=("$ex")
    done
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
  for d in "${SOURCES[@]}"; do
    name=$(sanitize_token "$(basename "$d")")
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

  # in a SHARED fs tree a per-source logical size is meaningless (files would
  # be counted several times): the logical total is the du of the whole fs/
  # once, the delta still per source (rsync stats report the actually
  # transferred bytes - the mover test with delta~0 reads exactly this).
  for d in "${SOURCES[@]}"; do
    name=$(sanitize_token "$(basename "$d")")
    local delta
    delta=$(awk '/^Total transferred file size:/{gsub(/,/,"",$5); print $5}' "$PROG_DIR/$name.log" 2>/dev/null || true)
    [ -z "$delta" ] && delta=0
    total_delta=$((total_delta + delta))
    ec=$(cat "$STATS_DIR/$name.exit" 2>/dev/null || echo 1)
    dmeta="${dmeta}\"${name}\":{\"exit\":${ec},\"delta_bytes\":${delta}},"
  done
  dmeta=${dmeta%,}
  logical=$(du -sb "$stage_root/fs" 2>/dev/null | awk '{print $1}')
  [ -z "$logical" ] && logical=0
  total_logical=$logical
  SWEEP_DELETED=0
  # Orphan-Sweep: only on a clean successful run (a stopped or failed run is
  # not berean); inside the staging copy, never against a visible snapshot.
  if [ "$state" = "success" ]; then
    if ! sweep_orphans "$stage_root"; then
      state="partial"
      log "run $RUN_ID demoted to partial: sweep aborted (source problem) - not promoted"
    fi
  fi
  # orphans stay visible in the meta (warning only, no jobs - Kap. 4.8)
  local ometa="[]"
  if [ ${#ORPHANS[@]} -gt 0 ]; then
    ometa=$(printf '%s\n' "${ORPHANS[@]}" | php -r '$l=array(); while(($x=fgets(STDIN))!==null){x=strim(x); if(x!="")l[]=x;} echo json_encode(l,64);')
    [ -z "$ometa" ] && ometa="[]"
  fi
  SWEEP_JSON="${SWEEP_DELETED:-0}"

  # .runmeta.json holds the disk leaf names only (JSON-safe); composed as raw
  # JSON and validated by json_decode inside write_json. A failure here must
  # never pass silently - the WebUI would show the run as "?" (the WebUI reads
  # ONLY this file), so retry with a minimal meta and shout into the syslog.
  local rmbody
  rmbody=$(printf '"run_id":"%s","state":"%s","started":"%s","finished":"%s","dry_run":false,"total_logical_bytes":%d,"total_delta_bytes":%d,"swept_deleted":%d,"orphan_dirs":%s,"sources":{%s}' \
    "$RUN_ID" "$state" "$started" "$(date '+%F %T')" "$total_logical" "$total_delta" "${SWEEP_JSON:-0}" "$ometa" "${dmeta%,}")
  if ! write_json "$stage_root/.runmeta.json" "$rmbody"; then
    syslog_err "run $RUN_ID: full .runmeta.json write failed (disk full?) - retrying minimal"
    if ! write_json "$stage_root/.runmeta.json" \
      "$(printf '"run_id":"%s","state":"%s","started":"%s","finished":"%s","dry_run":false,"total_logical_bytes":%d,"total_delta_bytes":%d,"sources":{}' \
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
    # perdisk still links to the shared fs tree (Disk-Historie stays browsable;
    # legacy runs keep their own diskN dirs, Kap. 10.6 "only migration")
    for d in "${SOURCES[@]}"; do
      name=$(sanitize_token "$(basename "$d")")
      mkdir -p "$CFG_TARGET/perdisk/$name"
      ln -sfn "../../runs/$RUN_ID/fs" "$CFG_TARGET/perdisk/$name/$RUN_ID"
    done
    # pershare: one symlink chain per covered share (restore view per share)
    for name in ${SHARES[@]+"${SHARES[@]}"}; do
      mkdir -p "$CFG_TARGET/pershare/$name"
      ln -sfn "../../runs/$RUN_ID/fs/$name" "$CFG_TARGET/pershare/$name/$RUN_ID"
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

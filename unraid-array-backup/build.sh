#!/bin/bash
# build.sh - erzeugt arraybackup.plg aus src/
# Nutzung: ./build.sh   (benoetigt base64, unter Linux/macOS/Git-Bash)
set -eu
cd "$(dirname "$0")"

VERSION="${VERSION:-2026.11.06.001}"
OUT="arraybackup.plg"

# GitHub-Adresse fuer Update-Pruefung: pluginURL muss auf die ROHE PLG-Datei
# zeigen (Repo-Unterpfad beachten!). ACHTUNG: Das GitHub-Repo muss OFFENTLICH
# sein - private Repos liefern auf raw.githubusercontent.com 404, dann kann
# der Plugin-Manager nicht nach Updates suchen (Update klappt nur manuell).
OWNER="${OWNER:-godghost123}"
REPO="${REPO:-back}"
PLG_PATH="${PLG_PATH:-unraid-array-backup/arraybackup.plg}"
RAWURL="https://raw.githubusercontent.com/${OWNER}/${REPO}/main/${PLG_PATH}"

# base64 als Einzeiler, ohne CR (CRLF aus Windows-Checkout -> kaputtes Base64)
b64() { tr -d '\r' < "$1" | base64 | tr -d '\n'; }
# SHA256 derselben CR-freien Bytes: das erzwingt den Austausch veralteter
# Dateien bei Update/Re-Install (der Manager ueberspringt sonst existierende).
sha() { tr -d '\r' < "$1" | sha256sum | cut -d' ' -f1; }

# Guard: Sources sollten im Checkout LF sein (.gitattributes regelt das; dieser
# Check faengt Abweichungen ab, bevor ein PLG mit doppelten CRs gebaut wird).
for f in src/ArrayBackup.page src/include/ajax.php src/include/engine.sh src/install.sh; do
  grep -q $'\r' "$f" && echo "WARN: $f enthaelt CRLF (core.autocrlf?) - baue trotzdem CR-frei" >&2
done || true

# Guard: install.sh (Self-heal des Registration-PLG) haelt die RAW-URL als
# Duplikat. Driften die beiden auseinander, wuerde der Server von einer
# anderen URL heilen als dieses PLG ausgeliefert wird -> Build abbrechen.
if ! grep -qF "$RAWURL" src/install.sh; then
  echo "ERROR: RAW-URL in src/install.sh weicht von build.sh ab:" >&2
  echo "  build.sh : $RAWURL" >&2
  echo "  install.sh enthaelt diese URL nicht - beide anpassen!" >&2
  exit 1
fi

# Wichtig: Eine PLG ist EINE XML-Datei mit GENAU EINEM Wurzelelement <PLUGIN>.
# Alle FILE-Elemente MUESSEN innerhalb von <PLUGIN>...</PLUGIN> stehen -
# sonst meldet emhttp "XML file doesn't exist or xml parse error".
{
cat <<EOF
<?xml version='1.0' standalone='yes'?>

<PLUGIN
  name="arraybackup"
  author="unraid-array-backup"
  version="${VERSION}"
  url="https://raw.githubusercontent.com/${OWNER}/${REPO}/main/${PLG_PATH}"
  pluginURL="https://raw.githubusercontent.com/${OWNER}/${REPO}/main/${PLG_PATH}"
  support="https://github.com/${OWNER}/${REPO}/issues"
  project="https://github.com/${OWNER}/${REPO}"
  launch="Utilities/ArrayBackup"
  icon="disk"
  min="6.10.0">

<CHANGES>
##arraybackup
###${VERSION}
- Fix: live progress display "disappears" mid-run. Causes fixed: (a) before
  the first file of a batch rsync re-prints "0% 0.00kB/s 0:00:00" placeholder
  lines (also after every retry) - those overwrote a bar that had real
  values; the parser now ignores 0%-placeholder lines and keeps the last
  good values (engine-side cache). (b) a retry truncated the progress log
  (> instead of >>), wiping the history; the delta extraction now reads the
  last --stats block. (c) finished sources kept showing a stale percentage
  and ETA forever (looked broken); they are now reported as done (green
  100% bar, "fertig"). (d) the WebUI re-renders bars each poll - values are
  now kept in sessionStorage per run id, so switching tabs/reloading the
  page no longer blanks the progress, and a poll that parses nothing keeps
  the last known values.
- Fix: install aborted with "plugin: run failed: /bin/bash returned 1" - the
  icon block (a ~20 KB base64 here-document inside a Run INLINE) is mangled on
  the server ("here-document delimited by end-of-file", "base64: invalid
  input"). Icon delivery reworked: a tiny mkdir Run-block first, then the PNG
  as a plain base64 FILE element (same proven path as engine.sh's 50 KB
  payload). Also fixes "Plugin not visible in Plugins tab" after the failed
  install: re-run plugin install from the URL once.
- Fix: plugin vanished from the Plugins tab (registration file
  /boot/config/plugins/arraybackup.plg was gone from flash - no update check
  possible, WebUI would die on reboot). install.sh now self-heals: every 30
  min (cron) it re-fetches this PLG from the raw URL when the registration is
  missing, and re-runs "plugin install" when the tmpfs payload is gone. If
  this update cannot reach the server (no registration left): run once, on
  the server console, "plugin install" with the raw URL of this PLG shown
  at the top of the repository README.
- Fix: "Start backup" did nothing. Share enumeration crashed with an empty
  array subscript: glob entries end in a slash, so taking the name after the
  last slash yielded an empty string; under set -e the engine then died
  silently. Share names are now stripped of the trailing slash first. Also:
  a source that CONTAINS the target (target=/mnt/backup/sub, /mnt/backup a
  pool) is no longer used as source - that would copy the backup into itself.
- Layout change: all sources (/mnt/diskN AND pool mounts like /mnt/cache) now
  write into ONE shared snapshot tree runs/RUN-ID/fs/ (per run). A file moved by the mover
  between two runs keeps its path in the backup and is hard-linked via the
  shared --link-dest (delta ~ 0) instead of being copied again. NOTE: the first
  run with the new layout copies completely (old diskN/-runs cannot link into
  it); afterwards runs are incremental. Old runs stay browsable and prune per
  retention. Deletions (file gone on disk or on cache) are mirrored per share
  after the transfers by an orphan-sweep (find+comm+rm, guarded; never via
  rsync --delete from an empty helper). Pool shares that never land on the
  array (e.g. Cache -> Backup) are NOT secured (warning banner only). Config:
  backup_pools, pool_filter, skip_shares; shareUseCache parsing (key name on
  server verified). UI entry moved from Settings to User Utilities.
- Fix: successful runs showing status "?" in the table. A failed
  .runmeta.json write was silent and the run was promoted anyway. Writes are
  now checked (retry with minimal meta, loud syslog on failure), promotion is
  refused without a readable meta, and existing runs stuck without meta are
  healed automatically from history.log on the next engine start.
- Fix: "target is not a mount point" for subdirectories of a mounted target.
  findmnt is now called as --target=PATH; the previous "-T -- PATH" form made
  getopt consume "--" as the value of -T, so the real path became an exact-
  match mountpoint filter and every subfolder of a mount was rejected.
- Atomic snapshots: every run builds inside .ab-staging/ on the target; only
  after a successful completion it is renamed (same-FS, atomic) into runs/ and
  the latest symlink is flipped. An aborted run never shows an apparently
  complete snapshot in the visible chain.
- rsync: --partial-dir=.rsync-partial instead of --partial (no truncated
  files inside a snapshot), --delete-delay, retry (max. 3) with backoff on
  transient failures (exit 10/11/12/30).
- Status/runmeta JSON is built with php json_encode and validated before
  writing - failure reasons now appear in the WebUI instead of vanishing.
- WebUI: paged array browser (500 entries + "load more"), single string
  table for all labels (de/en).
- Target path validated on save; pin/delete require a strict run id
  (r-YYYYMMDD-HHMMSS), reserved names such as latest are rejected.
- Icon: WebUI tile for the User-Utilities grid ships in the PLG
  (images/hard-disk.png, base64 with raw bytes - CR bytes inside the PNG are
  kept, hashing/encoding run over the un-modified file).
- Flash logs rotate when they exceed 1 MB.
- Previous: staged resume (Etappen), pluginURL fix, robust progress parsing.
</CHANGES>

EOF

# --- Dateien: <FILE> mit <INLINE> und Type="base64" auf dem FILE-Element
#     (so wie es /usr/local/emhttp/plugins/dynamix.plugin.manager/scripts/plugin
#     erwartet). install.sh erhaelt zusaetzlich Run="/bin/bash", laeuft also
#     bei Installation/Update/Boot (Cron re-instashen auf dem Flash-Overlay).
#     ArrayBackup.page registriert sich ueber seinen .page-Header (Menu="Utilities"
#     - proven on the server: user.scripts/unbalanced/nvidia-driver/vmbackup use
#     exactly this spelling for the "User Utilities" grid; "user" does NOT work)
#     in the "User Utilities"-Raster; launch accordingly. ---
for f in src/ArrayBackup.page src/include/ajax.php src/include/engine.sh src/install.sh; do
  if [ "$f" = "src/install.sh" ]; then
    dest="/boot/config/plugins/arraybackup/install.sh"; mode="0755"; run=" Run=\"/bin/bash\""
  else
    dest="/usr/local/emhttp/plugins/arraybackup/${f#src/}"
    mode="0755"; case "${f##*.}" in php|page) mode="0644";; esac
    run=""
  fi
  echo "<FILE Name=\"${dest}\" Type=\"base64\" Mode=\"${mode}\"${run}>"
  echo "<INLINE>"
  b64 "$f"
  echo "</INLINE>"
  # SHA256 der CR-freien Bytes: ohne Checksumme wuerde der Manager eine bereits
  # existierende Datei beim Update ueberspringen (alter Code bliebe liegen).
  echo "<SHA256>$(sha "$f")</SHA256>"
  echo "</FILE>"
  echo ""
done

# --- Icon: mkdir-run-block FIRST, then plain base64 FILE element ---
# Server-lesson (v004..v007): (1) the manager creates no parent dirs for FILE
# elements -> images/ must exist before the PNG FILE is written (v004 was
# silently skipped: empty images/). (2) a ~20 KB base64 HEREDOC inside a Run
# INLINE is mangled on the server (install aborted: "run failed ... 1").
# The base64 FILE path is proven (engine.sh 36 KB -> 50 KB inline decodes
# fine). Binary-safe: NO tr -d '\r' for the PNG (raw bytes + their SHA256).
cat <<'EOF'
<FILE Run="/bin/bash">
<INLINE><![CDATA[
mkdir -p /usr/local/emhttp/plugins/arraybackup/images
true
]]></INLINE>
</FILE>
EOF
echo ""
echo "<FILE Name=\"/usr/local/emhttp/plugins/arraybackup/images/hard-disk.png\" Type=\"base64\" Mode=\"0644\">"
echo "<INLINE>"
base64 src/include/hard-disk.png | tr -d '\n'
echo "</INLINE>"
echo "<SHA256>$(sha256sum src/include/hard-disk.png | cut -d' ' -f1)</SHA256>"
echo "</FILE>"
echo ""

# --- Statische Dateien + Setup-Kommandos (als FILE Run, <cmd> gibt es nicht) ---
cat <<'EOF'
<FILE Name="/boot/config/plugins/arraybackup/excludes.txt" Mode="0644">
<INLINE><![CDATA[
# rsync-Ausschlussmuster, eine pro Zeile
# Beispiel:
# .Trash-*/
# @eaDir/
]]></INLINE>
</FILE>

<FILE Run="/bin/bash">
<INLINE><![CDATA[
mkdir -p /usr/local/emhttp/plugins/arraybackup/images
mkdir -p /boot/config/plugins/arraybackup/logs
echo "arraybackup: directories ready"
]]></INLINE>
</FILE>

# --- Deinstallation: Plugin-Ordner loeschen (Backup-Ziel selbst bleibt heil).
#     Wichtig: fuer Run+INLINE-Ausfuehrung muss Name leer sein - mit Name wuerde
#     der Manager "$Run $Name" ausfuehren statt das Inline-Skript. ---
<FILE Run="/bin/bash" Method="remove">
<INLINE><![CDATA[
rm -rf /usr/local/emhttp/plugins/arraybackup
rm -rf /boot/config/plugins/arraybackup
/usr/local/sbin/update_cron
true
]]></INLINE>
</FILE>

</PLUGIN>
EOF
} > "$OUT"

# Plausibilitaetscheck: genau ein Wurzelelement, keine offenen Platzhalter.
# (Das fruehere `grep -c ... | grep -qv '^1$' && die Kette war falsch: bei genau
# einem Treffer lief sie in einen Non-Zero-Exit, der Check wurde nie wirksam.)
grep -q '</PLUGIN>' "$OUT" || { echo "ERROR: PLG hat kein schliessendes </PLUGIN>" >&2; exit 1; }
nroots=$(grep -c '<PLUGIN' "$OUT")
[ "$nroots" = "1" ] || { echo "ERROR: $nroots PLUGIN-Wurzelelemente (erwartet: 1)" >&2; exit 1; }

# Build-Gate: tools/validate_plg.py prueft XML, Base64-Payloads und SHA256 des
# fertigen PLG. Dieses PLG wird ueber die raw-URL ausgeliefert und beim naechsten
# Boot installiert - ein kaputtes PLG ist ein selbst verschuldeter Totalausfall,
# deshalb bricht der Build hier ab statt es auszuliefern.
if command -v python3 >/dev/null 2>&1; then PY=python3
elif command -v python >/dev/null 2>&1; then PY=python
elif command -v py >/dev/null 2>&1; then PY="py -3"
elif command -v uv >/dev/null 2>&1; then PY="uv run --no-project python"
else PY=""; fi
if [ -n "$PY" ]; then
  $PY tools/validate_plg.py "$OUT" || { echo "ERROR: validate_plg.py - PLG ungueltig, Build abgebrochen" >&2; exit 1; }
else
  echo "WARN: kein python gefunden - PLG-Validierung uebersprungen" >&2
fi

echo "built $OUT ($(wc -c < "$OUT") bytes)"

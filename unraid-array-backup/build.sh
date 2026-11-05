#!/bin/bash
# build.sh - erzeugt arraybackup.plg aus src/
# Nutzung: ./build.sh   (benoetigt base64, unter Linux/macOS/Git-Bash)
set -eu
cd "$(dirname "$0")"

VERSION="${VERSION:-2026.11.05.004}"
OUT="arraybackup.plg"

# GitHub-Adresse fuer Update-Pruefung: pluginURL muss auf die ROHE PLG-Datei
# zeigen (Repo-Unterpfad beachten!). ACHTUNG: Das GitHub-Repo muss OFFENTLICH
# sein - private Repos liefern auf raw.githubusercontent.com 404, dann kann
# der Plugin-Manager nicht nach Updates suchen (Update klappt nur manuell).
OWNER="${OWNER:-godghost123}"
REPO="${REPO:-back}"
PLG_PATH="${PLG_PATH:-unraid-array-backup/arraybackup.plg}"

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
  launch="user/ArrayBackup"
  icon="disk"
  min="6.10.0">

<CHANGES>
##arraybackup
###${VERSION}
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
- Flash logs rotate when they exceed 1 MB.
- Previous: staged resume (Etappen), pluginURL fix, robust progress parsing.
</CHANGES>

EOF

# --- Dateien: <FILE> mit <INLINE> und Type="base64" auf dem FILE-Element
#     (so wie es /usr/local/emhttp/plugins/dynamix.plugin.manager/scripts/plugin
#     erwartet). install.sh erhaelt zusaetzlich Run="/bin/bash", laeuft also
#     bei Installation/Update/Boot (Cron re-instashen auf dem Flash-Overlay).
#     ArrayBackup.page registriert sich ueber seinen .page-Header (Menu="user")
#     in den "User Utilities"-Raster der WebUI; launch accordingly. ---
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

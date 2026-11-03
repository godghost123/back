#!/bin/bash
# build.sh - erzeugt arraybackup.plg aus src/
# Nutzung: ./build.sh   (benoetigt base64, unter Linux/macOS/Git-Bash)
set -eu
cd "$(dirname "$0")"

VERSION="2026.11.03.009"
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
  launch="Settings/ArrayBackup"
  icon="disk"
  min="6.10.0">

<CHANGES>
##arraybackup
###${VERSION}
- Etappen-Betrieb: abgebrochene/gestoppte Laeufe werden beim naechsten Start
  fortgesetzt (rsync --partial, Fortschritts-Schalter "Abbruch fortsetzen").
  Damit kann auch das erste (Voll-)Backup in mehreren Etappen laufen.
- Vorherige: pluginURL-Korrektur (Update-Fix), Fortschritts-Anzeige robust
  gegen neue rsync-Formate, ausfuehrliche Fehlerausgabe (syslog + WebUI).
</CHANGES>

EOF

# --- Dateien: <FILE> mit <INLINE> und Type="base64" auf dem FILE-Element
#     (so wie es /usr/local/emhttp/plugins/dynamix.plugin.manager/scripts/plugin
#     erwartet). install.sh erhaelt zusaetzlich Run="/bin/bash", laeuft also
#     bei Installation/Update/Boot (Cron re-instashen auf dem Flash-Overlay).
#     ArrayBackup.page registriert sich ueber seinen .page-Header (Menu="Settings")
#     automatisch im Settings-Menue der WebUI. ---
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

# Plausibilitaetscheck: genau ein Wurzelelement, keine Platzhalter mehr offen
grep -q '</PLUGIN>' "$OUT" || { echo "ERROR: PLG hat kein schliessendes </PLUGIN>" >&2; exit 1; }
grep -c '<PLUGIN' "$OUT" | grep -qv '^1$' && { echo "ERROR: mehr als ein PLUGIN-Wurzelelement" >&2; exit 1; }

echo "built $OUT ($(wc -c < "$OUT") bytes)"

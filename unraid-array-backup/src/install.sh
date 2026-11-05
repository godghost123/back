#!/bin/bash
# ArrayBackup Post-Install/Boot-Skript: laeuft bei Installation, Update und
# jedem Boot (das <FILE> im PLG hat Run="/bin/bash"). /usr/local/emhttp ist
# ein fluechtiges tmpfs -> Verzeichnisse re-anlegen; der Zeitplan liegt als
# .cron-Datei auf dem Flash und wird ueber update_cron in die Crontab eingebunden.
CONF=/boot/config/plugins/arraybackup/config.json
mkdir -p /usr/local/emhttp/plugins/arraybackup/images
mkdir -p /boot/config/plugins/arraybackup/logs
[ -f "$CONF" ] || cat > "$CONF" <<JSON
{
  "target": "/mnt/backup",
  "retention_runs": 14,
  "retention_min_free_gb": 500,
  "max_jobs": 0,
  "bwlimit_kbps": 0,
  "dry_run": false,
  "resume_aborted": true,
  "exclude_file": "/boot/config/plugins/arraybackup/excludes.txt",
  "schedule_enabled": false,
  "schedule_cron": "0 2 * * 7",
  "backup_pools": true,
  "pool_filter": "",
  "skip_shares": ""
}
JSON
# --- Self-heal: das PLG-Registration-file auf dem Flash fehlen kann (z. B.
# versehentliches Remove oder loeschen). Ohne /boot/config/plugins/arraybackup.plg
# zeigt der Plugins-Tab nichts mehr -> kein Update-Check, und nach einem Reboot
# waere auch die tmpfs-WebUI weg. Plugin-Ordner + .cron + heal.sh ueberleben so
# einen Verlust (sie liegen auf dem Flash); heal.sh laeuft per Cron alle 30 min,
# laedt das PLG von der RAW-URL nach und installiert es neu, falls noetig.
# Die URL muss identisch zu build.sh sein (dort als Build-Gate gepueft).
RAWURL="https://raw.githubusercontent.com/godghost123/back/main/unraid-array-backup/arraybackup.plg"
cat > /boot/config/plugins/arraybackup/heal.sh <<HEAL
#!/bin/bash
PLG=/boot/config/plugins/arraybackup.plg
URL="$RAWURL"
if [ ! -f "\$PLG" ]; then
  if wget -q -O "\$PLG.new" "\$URL" && grep -q '<PLUGIN' "\$PLG.new"; then
    mv "\$PLG.new" "\$PLG"
    logger -p user.notice -t arraybackup "registration restored: \$PLG (fetched from \$URL)"
  else
    rm -f "\$PLG.new"
    logger -p user.warning -t arraybackup "heal: could not fetch \$URL (offline?)"
  fi
fi
# Registration da, aber tmpfs-Payload weg (Reboot ohne Boot-Re-Install) -> neu installieren
# (Cron-PATH enthaelt /usr/local/sbin nicht -> absolut aufrufen)
if [ -f "\$PLG" ] && [ ! -f /usr/local/emhttp/plugins/arraybackup/include/engine.sh ]; then
  logger -p user.notice -t arraybackup "tmpfs payload missing - reinstalling \$PLG"
  /usr/local/sbin/plugin install "\$PLG"
fi
true
HEAL
chmod 0755 /boot/config/plugins/arraybackup/heal.sh
# .cron-Datei im Plugin-Ordner auf dem Flash: /usr/local/sbin/update_cron
# (dynamix) kettet sie beim Boot/Plugin-Install automatisch in die Crontab ein.
# Zeile 1 = Backup-Zeitplan (nur wenn aktiviert), Zeile 2 = heal.sh immer.
php -r '
  $c = json_decode(file_get_contents($argv[1]), true) ?: [];
  $cron = "/boot/config/plugins/arraybackup/arraybackup.cron";
  $body = "";
  if (!empty($c["schedule_enabled"]) && !empty($c["schedule_cron"])) {
    $body = trim($c["schedule_cron"])." root nice -n 10 /usr/local/emhttp/plugins/arraybackup/include/engine.sh >> /boot/config/plugins/arraybackup/logs/cron.log 2>&1\n";
  }
  $body .= "*/30 * * * * root /boot/config/plugins/arraybackup/heal.sh >/dev/null 2>&1\n";
  file_put_contents($cron, $body);
' "$CONF" 2>/dev/null || true
/usr/local/sbin/update_cron

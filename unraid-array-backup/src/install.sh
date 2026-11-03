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
  "exclude_file": "/boot/config/plugins/arraybackup/excludes.txt",
  "schedule_enabled": false,
  "schedule_cron": "0 2 * * 7"
}
JSON
# .cron-Datei im Plugin-Ordner auf dem Flash: /usr/local/sbin/update_cron
# (dynamix) kettet sie beim Boot/Plugin-Install automatisch in die Crontab ein.
php -r '
  $c = json_decode(file_get_contents($argv[1]), true) ?: [];
  $cron = "/boot/config/plugins/arraybackup/arraybackup.cron";
  if (!empty($c["schedule_enabled"]) && !empty($c["schedule_cron"])) {
    file_put_contents($cron,
      trim($c["schedule_cron"])." root nice -n 10 /usr/local/emhttp/plugins/arraybackup/include/engine.sh >> /boot/config/plugins/arraybackup/logs/cron.log 2>&1\n");
  } else {
    @unlink($cron);
  }
' "$CONF" 2>/dev/null || true
/usr/local/sbin/update_cron

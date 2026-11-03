# ArrayBackup – C#-Port

C#-Kopie (NET 8) des unRAID-Plugins `unraid-array-backup/`: paralleles
rsync-Backup aller Array-Datendisks auf ein schnelles lokales Ziel,
Snapshot-Laeufe (`--link-dest`), Retention, Etappen-Fortsetzung, Weboberflaeche.

Das Original (`../unraid-array-backup/`) bleibt massgeblich fuer die
Unraid-Installation. Dieser Port ist ein eigenstaendiger Daemon/Server, der
auf Linux (auch Unraid, per Hand) und Windows laeuft.

## Aufbau (Original -> Port)

| Original (Shell/PHP)            | C#-Port                          |
|---------------------------------|----------------------------------|
| `engine.sh` (Lauf, rsync-Jobs)  | `src/Engine.cs`                  |
| `ajax.php` (JSON-API)           | `src/AjaxApi.cs` (`/ajax`)       |
| `ArrayBackup.page` (WebUI)      | `wwwroot/index.html` (identische UI) |
| `write_status()`/status.json    | `Engine.WriteStatus()` (gleiches JSON-Schema) |
| `syslog_err()` via `logger`     | `src/Syslog.cs` (/dev/log, Fallback `logger`) |
| Cron via `update_cron`          | `src/CronScheduler.cs` (In-Prozess, gleiche 5-Felder-Syntax) |
| emhttp-CSRF-Check               | `GET /csrf` + Pflicht in jedem POST (`src/AjaxApi.cs`, Csrf-Klasse) |
| PLG/Plugin-Manager              | entfaellt (Programmstart, `Program.cs`) |

## Bau und Start

```bash
dotnet build            # .NET 8 SDK erforderlich
dotnet run -- serve --port 8088
```

- `serve` (Default): WebUI auf http://localhost:8088, API unter `/ajax`,
  Scheduler laeuft mit (ausser `--no-scheduler`).
- `run-once`: genau ein Backup-Durchlauf, danach Exit (fiir Cron/Systemd).
- `stop`: setzt das Stop-Flag eines laufenden Daemons.
- `--config DIR` / `--run DIR`: Pfade (Default auf Linux wie im Original:
  `/boot/config/plugins/arraybackup` und `/var/run/arraybackup`; sonst
  `data/arraybackup` relativ zum Arbeitsverzeichnis).
- `ARRAYBACKUP_DISKS=pfad1;pfad2`: Disk-Quellen explicit setzen (Default:
  `/mnt/diskN`; auf Windows `data/mnt/diskN`). Fiir Tests/Inselbetrieb.
- `ARRAYBACKUP_MNT=/pfad`: Alternative zu `/mnt`.

Voraussetzungen wie im Original: `rsync` im PATH, Ziel mountbar und mit
Hardlink-Unterstuetzung (ext4/xfs/btrfs). `config.json` hat dieselben
Schluessel wie das Unraid-Plugin (target, retention_runs, resume_aborted, ...).

## Unterschiede zum Original

- Keine emhttp-Integration: Der CSRF-Schutz ist nachgebaut (Token von
  `/csrf`, in jedem POST noetig) statt vom WebUI-Daemon erzwungen.
- `latest` und `perdisk/...` sind echte Symlinks (Linux) bzw. werden auf
  Windows best-effort angelegt (Developer Mode/noetig); ohne Symlinks
  funktionieren Browser/Historie eingeschraenkt.
- Scheduler prueft alle 30 s im Prozess statt ueber Crontab-Dateien.
- Syslog via /dev/log bzw. `logger`; ohne beides wird still ignoriert.

## Selbsttest (Windows, ohne Unraid)

```powershell
mkdir data/mnt/disk1, data/mnt/disk1/sub -Force
"test" | Out-File data/mnt/disk1/afile.txt
dotnet run -- serve --port 8088
# Browser: http://localhost:8088 -> Konfiguration: Ziel z.B. data/target,
# Disks ueber ARRAYBACKUP_DISKS=data/mnt/disk1 setzen, Dry-Run starten.
```

Auf Linux mit echtem rsync laeuft der komplette Pfad inkl. Snapshots und
link-dest; unter Windows wird rsync benoetigt (z.B. über Git-Bash-Pfad oder
WSL), sonst bricht der Lauf mit "rsync not found" ab (wie im Original).

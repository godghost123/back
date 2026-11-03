# ArrayBackup – unRAID Plugin

Sichert alle Datendisks des unRAID-Arrays **gleichzeitig parallel** (je Disk ein `rsync`-Job) und schreibt **gebündelt auf ein schnelles, lokal angeschlossenes Ziel** (z. B. RAID0 aus NVMe/SSDs). Jeder Lauf erzeugt einen **vollständigen Snapshot des gesamten Arrays** – space-effizient über harte Links (`rsync --link-dest`, Time-Machine-Prinzip).

Paritäts-Platten werden automatisch übersprungen (unter `/mnt` nicht gemountet und aus den Datendisks rekonstruierbar).

## Features

- **Paralleles Lesen, gebündeltes Schreiben:** alle Datendisks werden gleichzeitig eingelesen, die Schreibströme sättigen das RAID0-Ziel
- **Array-Snapshots:** jeder Lauf sieht aus wie eine Komplett-Sicherung des Arrays (`runs/<timestamp>/disk1 … diskN`)
- **Disk-Historie:** pro Disk eine chronologische Kette (`perdisk/diskN/<timestamp>` als Symlinks)
- **Space-effizient:** unveränderte Dateien sind harte Links auf den vorherigen Lauf
- **Retention:** behält die letzten N Läufe, Mindest-Freiraum-Guard, einzelne Läufe anheften (Pinning)
- **WebUI** im Settings-Menü: Live-Fortschritt pro Disk, Snapshot-Tabelle, Array-Browser, Disk-Historie, Konfiguration
- **Scheduler:** Cron-Eintrag auf Flash (`/boot/config/plugins/arraybackup/arraybackup.cron`), bei jedem Boot via `update_cron` re-aktiviert
- **Sicherheit:** Lockfile gegen Doppelstarts, Selbst-Backup-Schutz, Freiraum-Check, Dry-Run-Modus, Traversal-Schutz im Browser

## Voraussetzungen

- unRAID 6.12+ (6.10/6.11 funktionieren in der Regel ebenfalls)
- Backup-Ziel **lokal** am Server gemountet (z. B. `/mnt/backup`), Dateisystem **ext4/xfs/btrfs** (harte Links nötig; FAT/exFAT wird abgelehnt)
- `rsync` ist auf unRAID vorhanden; `php`/`flock`/`findmnt` sind Bestandteil von unRAID

## Installation

> **Wichtig:** Frühere, fehlgeschlagene Installationsversuche hinterlassen alte
> `.plg`-Kopien in `/boot/config/plugins-error/` (im WebUI: Plugins → Reiter
> „Plugin File Install Errors"). Diese dort **löschen**, sonst werden sie bei
> jedem Boot erneut installiert und schlagen ggf. wieder fehl. Ebenso eine alte
> `/boot/config/plugins/arraybackup.plg` entfernen, bevor die neue installiert wird.

Lokale Installation (ohne GitHub-Repo):

1. `arraybackup.plg` auf den USB-Flash-Stick kopieren, z. B. nach
   `/boot/config/plugins/arraybackup.plg` (SMB-Freigabe `\\\\server\\boot\\config\\plugins\\`).
2. WebUI → **Plugins**: die Plugin-Datei wird beim nächsten Boot automatisch
   installiert, oder sofort über das Eingabefeld „Install Plugin" mit dem
   Pfad `/boot/config/plugins/arraybackup.plg` (ggf. „Force Break" aktivieren,
   wenn dieselbe Version schon gelistet ist). Alternativ in der Konsole:
   `plugin install /boot/config/plugins/arraybackup.plg`
3. WebUI neu laden → **Settings → ArrayBackup** erscheint im Menü.
4. Tab **Konfiguration**: Ziel-Mountpoint eintragen (z. B. `/mnt/backup`), speichern.
5. Erstmalig **Dry-Run** aktivieren und „Backup starten" klicken, dann Dry-Run aus und echten Lauf starten.

Hinweis: Solange `OWNER`/`REPO` in `build.sh` Platzhalter sind, zeigt die
Plugin-Liste nur eine Warnung beim Update-Check – die lokale Installation
funktioniert dadurch dennoch.

### Update / erneut installieren

Der Plugin-Manager überschreibt vorhandische Dateien nur, wenn ihre SHA256
im PLG nicht passt – das ist durch die generierten `<SHA256>`-Blöcke abgedeckt.
Zwischenständen beim Entwickeln zusätzlich hilft:

```bash
rm -rf /usr/local/emhttp/plugins/arraybackup   # tmpfs, geht auch per Reboot
plugin install /boot/config/plugins/arraybackup.plg
```

Aus dem Quellcode bauen (Linux/macOS/Git-Bash):

```bash
./build.sh   # erzeugt arraybackup.plg
```

## Zielstruktur

```
/mnt/backup/
├── runs/
│   └── r-20261103-020000/
│       ├── .runmeta.json      # Status, Exit-Codes, logische & Delta-Größe pro Disk
│       ├── .pinned            # nur wenn Lauf angeheftet
│       ├── disk1/  disk2/ …   # Komplett-Sicht: Array „als Ganzes" gesichert
├── latest -> runs/r-…         # letzter erfolgreicher Lauf
└── perdisk/
    └── disk1/r-… -> ../../runs/r-…/disk1   # Disk-Historie (Symlinks)
```

## Funktionsweise

1. Engine prüft: Array läuft, Ziel gemountet, kein Backup auf das Array selbst, Dateisystem unterstützt harte Links, genug Freiraum.
2. Neues Laufverzeichnis `runs/r-<JJJJMMTT-HHMMSS>/` wird angelegt.
3. Pro Datendisk startet gleichzeitig ein `rsync -aHAX --numeric-ids --delete --link-dest=<letzter erfolgreicher Lauf>/<disk>`; `--link-dest` macht unveränderte Dateien zu harte Links.
4. Nach Abschluss: `.runmeta.json` schreiben, `latest`-Symlink und `perdisk/`-Farm aktualisieren, Retention anwenden (Anzahl + Freiraum-Guard, gepinnte Läufe bleiben).
5. Fortschritt liegt in `/var/run/arraybackup/status.json` (RAM), Lauf-Summen in `/boot/config/plugins/arraybackup/logs/` (flash-schonend).

## Testanleitung

| Szenario | Vorgehen | Erwartung |
|---|---|---|
| Dry-Run | Dry-Run aktivieren, Start | rsync `-n`, es entsteht **kein** Laufverzeichnis |
| Snapshot-Kette | 2 Läufe, danach `stat runs/r-*/disk1/<gleiche Datei>` | identische Inode = harter Link, Delta-Größe ≈ nur Änderungen |
| Abbruch | Während Lauf „Stopp" | Lauf-Status `aborted`, nächster `--link-dest` bleibt der letzte `success` |
| Doppelstart | Start während Lauf | zweite Engine bricht sofort mit Lock-Meldung ab |
| Retention | `retention_runs=3`, 5 Läufe, einen pinnen | genau 3 unpinned behalten, gepinnt bleibt, `latest`/`perdisk` konsistent |
| Selbst-Backup | Ziel auf `/mnt/disk1` zeigen lassen | Engine verweigert mit Fehlermeldung |

## Dateien

| Datei | Zweck |
|---|---|
| `arraybackup.plg` | fertiges Plugin-Manifest (generiert) |
| `build.sh` | erzeugt das `.plg` aus `src/` |
| `src/ArrayBackup.page` | WebUI mit `.page`-Header (`Menu="Settings"`); Tabs: Backups, Array-Browser, Disk-Historie, Konfiguration |
| `src/install.sh` | Post-Install-Skript (Verzeichnisse, Default-Config, Cron auf Flash) |
| `src/include/ajax.php` | JSON-API (`config-get/-save`, `start`, `stop`, `status`, `runs`, `ls`, `pin`, `delete-run`) |
| `src/include/engine.sh` | Backup-Engine (Parallel-rsync, Snapshots, Retention, Logging) |

## Bekannte Grenzen / Ausbaustufen

- v1 spiegelt **Disks**, nicht Shares (Share-Union-View als Ausbaustufe denkbar)
- keine Prüfsummen-Verifikation, keine Benachrichtigungen
- Retention nach Anzahl statt GFS-Schema

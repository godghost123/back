<?php
/* arraybackup - ajax.php
 * JSON-API fuer WebUI und Scheduler:
 *   action=config-get | config-save | start | stop | status | runs | ls | pin
 *   | delete-run | restore-start | restore-status | restore-stop | shares-list
 */

$PLUGIN    = 'arraybackup';
$CONF_DIR  = "/boot/config/plugins/$PLUGIN";
$CONF_FILE = "$CONF_DIR/config.json";
$RUN_DIR   = "/var/run/$PLUGIN";
$STATUS    = "$RUN_DIR/status.json";
$STOP_FLAG = "$RUN_DIR/stop.flag";
$ENGINE    = "/usr/local/emhttp/plugins/$PLUGIN/include/engine.sh";
$CRON_FILE = "$CONF_DIR/$PLUGIN.cron";
// async restore (restore.sh): own pid/status/stop files so a restore never
// collides with the backup engine's files
$RESTORE       = "/usr/local/emhttp/plugins/$PLUGIN/include/restore.sh";
$RESTORE_STAT  = "$RUN_DIR/restore.json";
$RESTORE_STOP  = "$RUN_DIR/restore.stop.flag";

function jout($data) {
    header('Content-Type: application/json');
    echo json_encode($data);
    exit;
}
function jerr($msg) { jout(['ok' => false, 'error' => $msg]); }

function load_config() {
    global $CONF_DIR, $CONF_FILE;
    if (!is_dir($CONF_DIR)) @mkdir($CONF_DIR, 0777, true);
    $c = is_file($CONF_FILE) ? (json_decode(file_get_contents($CONF_FILE), true) ?: []) : [];
    $c += [
        'target' => '/mnt/backup',
        'retention_runs' => 14,
        'retention_min_free_gb' => 500,
        'max_jobs' => 0,
        'bwlimit_kbps' => 0,
        'dry_run' => false,
        'resume_aborted' => true,
        'exclude_file' => "$CONF_DIR/excludes.txt",
        'schedule_enabled' => false,
        'schedule_cron' => '0 2 * * 7',
        // merged fs/ layout: sources = /mnt/diskN + pool mounts.
        // MUST stay identical to src/install.sh and engine.sh load_config.
        'backup_pools' => true,
        'pool_filter' => '',
        'skip_shares' => '',
    ];
    return $c;
}

function write_cron($c) {
    global $CRON_FILE;
    // Zeile 1 (optional): Backup-Zeitplan. Zeile 2 (IMMER): heal.sh - die
    // Selbstheilung der PLG-Registration (identisch zu install.sh; beide
    // schreiben dieselbe Datei, sonst verschwindet der Heal beim Config-Speichern).
    //
    // OHNE user-Feld: die .cron-Dateien landen in /etc/cron.d/root, und Unraid
    // liest diese Eintraege ohne user-Feld (genau so erzeugt update_cron auch
    // alle anderen Zeilen). Ein "root" an Stelle 6 waere dort nicht der
    // Benutzer, sondern der BEFEHL -> "/bin/sh: line 1: root: command not
    // found", der eigentliche Job laeuft nie. Also: Zeitfelder, dann direkt
    // der Befehl (der Cron-Prozess laeuft auf Unraid ohnehin als root).
    $body = '';
    if (!empty($c['schedule_enabled']) && preg_match('/^[\d*\/, -]+ [\d*\/, -]+ [\d*\/, -]+ [\d*\/, -]+ [\d*\/, -]+$/', trim($c['schedule_cron']))) {
        $body = trim($c['schedule_cron'])." nice -n 10 /usr/local/emhttp/plugins/arraybackup/include/engine.sh >> /boot/config/plugins/arraybackup/logs/cron.log 2>&1\n";
    }
    $body .= "*/30 * * * * /boot/config/plugins/arraybackup/heal.sh >/dev/null 2>&1\n";
    file_put_contents($CRON_FILE, $body);
    // Crontab aus allen Flash-.cron-Dateien neu bauen (dynamix-Mechanismus,
    // ueberlebt Reboots; /etc/cron.d selbst ist fluechtiges tmpfs)
    @exec('/usr/local/sbin/update_cron 2>/dev/null');
}

function engine_running() {
    global $RUN_DIR;
    $pid = (int)trim((string)@file_get_contents("$RUN_DIR/engine.pid"));
    if ($pid <= 0 || !is_dir("/proc/$pid")) return false;
    // pid files go stale and pids get reused - only report "running" while the
    // process is actually our engine (cmdline contains engine.sh)
    $cmd = @file_get_contents("/proc/$pid/cmdline");
    return $cmd !== false && strpos($cmd, 'engine.sh') !== false;
}

function restore_running() {
    global $RUN_DIR;
    $pid = (int)trim((string)@file_get_contents("$RUN_DIR/restore.pid"));
    if ($pid <= 0 || !is_dir("/proc/$pid")) return false;
    $cmd = @file_get_contents("/proc/$pid/cmdline");
    return $cmd !== false && strpos($cmd, 'restore.sh') !== false;
}

// Restore-target guard. The operator picks where a file/folder goes back to
// (/mnt/user/<...> for the original share, or a test folder). Refuse paths
// that could hurt the system or the backup chain itself:
//  - relative paths and / itself
//  - system directories (/boot holds flash+config, /etc,/usr,/var,... rwired)
//  - inside the backup target (restoring a snapshot into the snapshot chain)
//  - INTO a parent of the target (would drop files next to runs/)
// returns an error string or false when ok.
function restore_dest_error($dest, $targetRoot) {
    $dest = rtrim(str_replace('\\', '/', trim((string)$dest)), '/');
    if ($dest === '' || $dest[0] !== '/' || $dest === '/') {
        return 'restore target must be an absolute path (e.g. /mnt/user/games)';
    }
    if (preg_match('#^/(boot|etc|usr|var|sys|proc|dev|root|lib|bin|sbin)(/|$)#', $dest)) {
        return 'refusing to restore into a system path: '.$dest;
    }
    if ($dest === $targetRoot || strpos($dest, $targetRoot.'/') === 0) {
        return 'refusing to restore inside the backup target itself: '.$dest;
    }
    if (strpos($targetRoot, $dest.'/') === 0) {
        return 'refusing to restore into a parent of the backup target (mixes restored data with the snapshot chain): '.$dest;
    }
    return false;
}

function safe_target_path($c, $rel) {
    $root = realpath($c['target']);
    if ($root === false) return false;
    $rel = ltrim(str_replace('\\', '/', $rel), '/');
    if ($rel === '') return $root;
    $test = $root.'/'.$rel;
    $real = realpath(dirname($test));
    if ($real === false) return false;
    $full = $real.'/'.basename($test);
    if ($full !== $root && strpos($full, $root.'/') !== 0) return false; // traversal protection
    return $full;
}

$action = $_POST['action'] ?? $_GET['action'] ?? '';
$c = load_config();

/* CSRF: emhttp (WebUI-Daemon) prueft den csrf_token ALLEIN und verwirft
 * POSTs ohne gueltigen Token ("missing csrf_token" im syslog), BEVOR diese
 * Datei ueberhaupt ausgefuehrt wird. Erreicht ajax.php ein POST, ist der
 * Token also bereits gueltig. Eigene Nachpruefung gegen var.ini auf Disk
 * waere fehleranfaellig: var.ini hinkt dem Session-Token hinterher
 * (Token rotiert, Datei wird spaeter beschrieben) -> falsche
 * "abgelaufen"-Meldungen. Deshalb hier bewusst KEINE eigene Pruefung. */

switch ($action) {

case 'config-get':
    $c['excludes'] = is_file($c['exclude_file']) ? file_get_contents($c['exclude_file']) : '';
    jout(['ok' => true, 'config' => $c]);

case 'config-save':
    foreach (['target','exclude_file','schedule_cron'] as $k) {
        if (isset($_POST[$k])) $c[$k] = trim($_POST[$k]);
    }
    // Reject an impossible target at SAVE time instead of failing at the next
    // scheduled run at 02:00 - mirrors the engine's own validate() guard.
    if (isset($_POST['target'])) {
        $t = $c['target'];
        if ($t === '' || $t[0] !== '/') jerr('target must be an absolute mountpoint path (e.g. /mnt/backup)');
        $real = realpath($t);
        if ($real !== false && preg_match('#^/mnt/(disk[0-9]+|user|share)(/|$)#', $real)) {
            jerr('refusing to back up onto the array itself: '.$real);
        }
    }
    foreach (['retention_runs','retention_min_free_gb','max_jobs','bwlimit_kbps'] as $k) {
        if (isset($_POST[$k])) $c[$k] = max(0, (int)$_POST[$k]);
    }
    $c['dry_run'] = !empty($_POST['dry_run']);
    $c['resume_aborted'] = !empty($_POST['resume_aborted']);
    $c['schedule_enabled'] = !empty($_POST['schedule_enabled']);
    // backup_pools: checkbox -> absent field keeps the current value
    if (isset($_POST['backup_pools'])) $c['backup_pools'] = !empty($_POST['backup_pools']);
    foreach (['pool_filter','skip_shares'] as $k) {
        if (isset($_POST[$k])) $c[$k] = trim($_POST[$k]);
    }
    if (!empty($_POST['excludes'])) {
        @file_put_contents($c['exclude_file'], str_replace("\r\n", "\n", $_POST['excludes']));
    }
    if (!is_dir(dirname($c['exclude_file']))) @mkdir(dirname($c['exclude_file']), 0777, true);
    if (!is_file($c['exclude_file'])) @touch($c['exclude_file']);
    file_put_contents($CONF_FILE, json_encode($c, JSON_PRETTY_PRINT));
    write_cron($c);
    jout(['ok' => true]);

case 'start':
    if (engine_running()) jerr('a backup is already running');
    // hardlinking a still-restored tree would snapshot half-restored state
    if (restore_running()) jerr('a restore is running - wait for it to finish');
    if (!is_file($ENGINE)) jerr('engine.sh not found');
    @mkdir("$CONF_DIR/logs", 0777, true);
    $cmd = 'nohup bash '.$ENGINE.' >> '.$CONF_DIR.'/logs/engine.log 2>&1 &';
    exec($cmd);
    jout(['ok' => true]);

case 'stop':
    if (!engine_running()) jerr('no backup running');
    @mkdir($RUN_DIR, 0777, true);
    file_put_contents($STOP_FLAG, (string)time());
    jout(['ok' => true]);

case 'status':
    $s = is_file($STATUS) ? (json_decode(file_get_contents($STATUS), true) ?: []) : [];
    $s['engine_running'] = engine_running();
    jout(['ok' => true, 'status' => $s]);

case 'runs':
    $runs = [];
    $runsDir = rtrim($c['target'], '/').'/runs';
    $latest = realpath(rtrim($c['target'], '/').'/latest') ?: '';
    if (!is_dir(rtrim($c['target'], '/'))) jerr('backup target not mounted: '.$c['target']);
    if (is_dir($runsDir)) {
        $dirs = glob("$runsDir/r-*", GLOB_ONLYDIR) ?: [];
        rsort($dirs);
        foreach ($dirs as $d) {
            $meta = is_file("$d/.runmeta.json") ? (json_decode(file_get_contents("$d/.runmeta.json"), true) ?: []) : [];
            $runs[] = [
                'id'      => basename($d),
                'pinned'  => is_file("$d/.pinned"),
                'is_latest' => ($latest !== '' && realpath($d) === $latest),
                'meta'    => $meta,
            ];
        }
    }
    jout(['ok' => true, 'runs' => $runs, 'target' => $c['target']]);

case 'ls':
    // Unbounded listings froze the browser/emhttp on disks with 100k+ files.
    // Pagination: sort names only, stat just the requested slice.
    $rel = $_GET['path'] ?? $_POST['path'] ?? '';
    $full = safe_target_path($c, $rel);
    if ($full === false || !is_dir($full)) jerr('invalid path');
    $offset = max(0, (int)($_GET['offset'] ?? $_POST['offset'] ?? 0));
    $limit  = (int)($_GET['limit'] ?? $_POST['limit'] ?? 500);
    if ($limit < 1 || $limit > 2000) $limit = 500;
    $names = array_values(array_filter(scandir($full) ?: [], fn($e) => $e !== '.' && $e !== '..'));
    sort($names, SORT_NATURAL);
    $total = count($names);
    $entries = [];
    foreach (array_slice($names, $offset, $limit) as $e) {
        $p = "$full/$e";
        $isDir = is_dir($p);
        $entries[] = [
            'name' => $e,
            'dir'  => $isDir,
            'size' => $isDir ? null : (int)@filesize($p),
            'mtime'=> (int)@filemtime($p),
        ];
    }
    usort($entries, fn($a, $b) => [$b['dir'], $a['name']] <=> [$a['dir'], $b['name']]);
    jout(['ok' => true, 'path' => $rel, 'offset' => $offset,
          'count' => count($entries), 'total' => $total,
          'truncated' => $offset + count($entries) < $total,
          'entries' => $entries]);

case 'pin':
    // Strict id shape (engine generates r-YYYYMMDD-HHMMSS): a typo like
    // 'latest', 'runs' or 'perdisk' must never reach rm -rf / unlink paths.
    $id = (string)($_POST['run'] ?? '');
    if (!preg_match('/^r-\d{8}-\d{6}$/', $id)) jerr('invalid run id');
    $d = rtrim($c['target'], '/').'/runs/'.$id;
    if (!is_dir($d)) jerr('run not found');
    is_file("$d/.pinned") ? @unlink("$d/.pinned") : @touch("$d/.pinned");
    jout(['ok' => true, 'pinned' => is_file("$d/.pinned")]);

case 'delete-run':
    $id = (string)($_POST['run'] ?? '');
    if (!preg_match('/^r-\d{8}-\d{6}$/', $id)) jerr('invalid run id');
    $target = rtrim($c['target'], '/');
    $d = "$target/runs/$id";
    if (!is_dir($d)) jerr('run not found');
    if (engine_running() || restore_running()) jerr('cannot delete while a backup or restore is running');
    $isLatest = (realpath("$target/latest") === realpath($d));
    exec('rm -rf '.escapeshellarg($d));
    // legacy perdisk//pershare symlinks of older
    // versions - these link roots are not created anymore, but leftovers
    // from previous installs still have to go when their run dies.
    foreach (glob("$target/perdisk/*/$id") ?: [] as $link) @unlink($link);
    foreach (glob("$target/pershare/*/$id") ?: [] as $link) @unlink($link);
    if ($isLatest) {
        @unlink("$target/latest");
        $dirs = glob("$target/runs/r-*", GLOB_ONLYDIR) ?: [];
        rsort($dirs);
        foreach ($dirs as $nd) {
            $m = json_decode(@file_get_contents("$nd/.runmeta.json") ?: '', true) ?: [];
            if (($m['state'] ?? '') === 'success') {
                @symlink('runs/'.basename($nd), "$target/latest");
                break;
            }
        }
    }
    jout(['ok' => true]);

case 'shares-list':
    // Top-level shares of one run (for the restore target dropdown). Reads the
    // run's own fs/ tree directly - the old pershare/ symlink view is gone.
    $id = (string)($_POST['run'] ?? $_GET['run'] ?? '');
    if (!preg_match('/^r-\d{8}-\d{6}$/', $id)) jerr('invalid run id');
    $runDir = rtrim($c['target'], '/').'/runs/'.$id;
    if (!is_dir($runDir)) jerr('run not found');
    $root = is_dir("$runDir/fs") ? "$runDir/fs" : $runDir;
    $names = array_values(array_filter(scandir($root) ?: [],
        fn($e) => $e !== '.' && $e !== '..' && $e[0] !== '.' && is_dir("$root/$e")));
    sort($names, SORT_NATURAL);
    jout(['ok' => true, 'entries' => array_map(fn($n) => ['name' => $n], $names)]);

case 'restore-start':
    // Everything runs through restore.sh (nohup, env vars NOT $argv - see the
    // register_argc_argv lesson in engine.sh). Guarded exactly like the engine:
    // strict run id, no traversal, no meta entries, target outside the chain.
    $id = (string)($_POST['run'] ?? '');
    if (!preg_match('/^r-\d{8}-\d{6}$/', $id)) jerr('invalid run id');
    if (engine_running()) jerr('a backup is running - restore is disabled during a backup');
    if (restore_running()) jerr('a restore is already running');
    $targetRoot = realpath($c['target']);
    if ($targetRoot === false) jerr('backup target not mounted: '.$c['target']);
    $rel = ltrim(str_replace('\\', '/', trim((string)($_POST['src'] ?? ''))), '/');
    $base = 'runs/'.$id;
    if (strpos($rel, $base.'/') !== 0 || strlen($rel) <= strlen($base) + 1) {
        jerr('restore source must be inside the selected run');
    }
    foreach (explode('/', substr($rel, strlen($base) + 1)) as $seg) {
        // .runmeta.json / .pinned / .ab-staging / dotfiles are plugin meta, not user data
        if ($seg === '' || $seg[0] === '.') jerr('meta or hidden entries cannot be restored: '.$seg);
    }
    $src = safe_target_path($c, $rel);
    if ($src === false || (!is_file($src) && !is_dir($src))) jerr('restore source not found: '.$rel);
    $dest = (string)($_POST['dest'] ?? '');
    $err = restore_dest_error($dest, $targetRoot);
    if ($err !== false) jerr($err);
    $dest = rtrim(str_replace('\\', '/', trim($dest)), '/');
    $mode = (($_POST['mode'] ?? '') === 'skip') ? 'skip' : 'overwrite';
    if (!is_file($RESTORE)) jerr('restore.sh not found');
    @mkdir($RUN_DIR, 0777, true);
    @mkdir("$CONF_DIR/logs", 0777, true);
    // placeholder status so the WebUI shows a live card immediately (restore.sh
    // rewrites it with real values within seconds)
    @file_put_contents($RESTORE_STAT, json_encode([
        'state' => 'running', 'run_id' => $id, 'updated' => date('Y-m-d H:i:s'),
        'elapsed' => 0, 'label' => $rel, 'dest' => $dest, 'mode' => $mode,
        'progress' => ['pct' => '', 'rate' => '', 'eta' => ''],
    ]));
    $cmd = 'nohup env AB_SRC='.escapeshellarg($src).' AB_DEST='.escapeshellarg($dest)
         .' AB_MODE='.$mode.' AB_RID='.$id.' AB_LABEL='.escapeshellarg($rel)
         .' bash '.escapeshellarg($RESTORE).' >> '.$CONF_DIR.'/logs/restore.log 2>&1 &';
    exec($cmd);
    jout(['ok' => true, 'dest' => $dest]);

case 'restore-status':
    $s = is_file($RESTORE_STAT) ? (json_decode(file_get_contents($RESTORE_STAT), true) ?: []) : [];
    $s['running'] = restore_running();
    // kill -9 / power loss leaves "running" forever - report the truth instead
    if (!$s['running'] && ($s['state'] ?? '') === 'running') $s['state'] = 'lost';
    jout(['ok' => true, 'restore' => $s]);

case 'restore-stop':
    if (!restore_running()) jerr('no restore running');
    @mkdir($RUN_DIR, 0777, true);
    file_put_contents($RESTORE_STOP, (string)time());
    jout(['ok' => true]);

default:
    jerr('unknown action');
}

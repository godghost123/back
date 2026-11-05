<?php
/* arraybackup - ajax.php
 * JSON-API fuer WebUI und Scheduler:
 *   action=config-get | config-save | start | stop | status | runs | ls | pin | delete-run
 */

$PLUGIN    = 'arraybackup';
$CONF_DIR  = "/boot/config/plugins/$PLUGIN";
$CONF_FILE = "$CONF_DIR/config.json";
$RUN_DIR   = "/var/run/$PLUGIN";
$STATUS    = "$RUN_DIR/status.json";
$STOP_FLAG = "$RUN_DIR/stop.flag";
$ENGINE    = "/usr/local/emhttp/plugins/$PLUGIN/include/engine.sh";
$CRON_FILE = "$CONF_DIR/$PLUGIN.cron";

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
    $body = '';
    if (!empty($c['schedule_enabled']) && preg_match('/^[\d*\/, -]+ [\d*\/, -]+ [\d*\/, -]+ [\d*\/, -]+ [\d*\/, -]+$/', trim($c['schedule_cron']))) {
        $body = trim($c['schedule_cron'])." root nice -n 10 /usr/local/emhttp/plugins/arraybackup/include/engine.sh >> /boot/config/plugins/arraybackup/logs/cron.log 2>&1\n";
    }
    $body .= "*/30 * * * * root /boot/config/plugins/arraybackup/heal.sh >/dev/null 2>&1\n";
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
    if (engine_running()) jerr('cannot delete while a backup is running');
    $isLatest = (realpath("$target/latest") === realpath($d));
    exec('rm -rf '.escapeshellarg($d));
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

default:
    jerr('unknown action');
}

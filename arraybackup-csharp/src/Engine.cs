using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace ArrayBackup;

/// <summary>
/// C#-Port von engine.sh: fuehrt Backup-Laeufe aus (ein rsync-Job pro Datendisk),
/// schreibt status.json (identisches Schema), unterstuetzt Stop-Flag,
/// Etappen-Fortsetzung abgebrochener Läufe, Retention und Freiraum-Guard.
/// </summary>
public sealed class Engine
{
    private readonly EnginePaths _p;
    private readonly object _gate = new();
    private readonly object _logGate = new();
    private FileStream? _lockHandle;
    private readonly List<Process> _rsyncProcs = new();
    private List<string> _disks = new();

    public Engine(EnginePaths paths) { _p = paths; }

    public EnginePaths Paths => _p;
    public bool IsRunning { get; private set; }

    // ============================================================ Start/Stop

    public string? StartBackground()
    {
        lock (_gate)
        {
            if (IsRunning) return "a backup is already running";
            if (!TryTakeLock()) return "another backup is already running";
            IsRunning = true;
            var t = new Thread(() =>
            {
                try { RunGuarded(); }
                finally { lock (_gate) { IsRunning = false; ReleaseLock(); } }
            })
            { IsBackground = true, Name = "arraybackup-engine" };
            t.Start();
            return null;
        }
    }

    public string? RunOnceBlocking()
    {
        if (IsRunning) return "a backup is already running";
        if (!TryTakeLock()) return "another backup is already running";
        try { return RunGuarded(); }
        finally { ReleaseLock(); }
    }

    public string? Stop()
    {
        if (!IsRunning) return "no backup running";
        RequestStopExternal();
        KillAll();
        return null;
    }

    public void RequestStopExternal()
    {
        Directory.CreateDirectory(_p.RunDir);
        File.WriteAllText(_p.StopFlag, DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString());
    }

    private bool TryTakeLock()
    {
        try
        {
            Directory.CreateDirectory(_p.RunDir);
            // FileShare.None == flock -n: wirft IOException, haelt ein anderer Prozess die Datei
            _lockHandle = new FileStream(_p.LockFile, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            return true;
        }
        catch (IOException) { _lockHandle = null; return false; }
    }

    private void ReleaseLock()
    {
        try { _lockHandle?.Dispose(); } catch { }
        _lockHandle = null;
    }

    private void KillAll()
    {
        lock (_rsyncProcs)
        {
            foreach (var pr in _rsyncProcs)
            {
                try { pr.Kill(entireProcessTree: true); } catch { }
            }
        }
    }

    // port von validate() aus engine.sh. Rueckgabe: null = ok, sonst Fehlermeldung.

    /// <summary>Port von main() aus engine.sh. Gibt Fehlermeldung zurueck oder null.</summary>
    private string? RunGuarded()
    {
        Directory.CreateDirectory(_p.RunDir);
        Directory.CreateDirectory(_p.LogDir);
        File.WriteAllText(_p.PidFile, Environment.ProcessId.ToString());
        TryDeleteFile(_p.StopFlag);
        TryDeleteDir(_p.ProgressDir);
        TryDeleteDir(_p.StatsDir);
        Directory.CreateDirectory(_p.ProgressDir);
        Directory.CreateDirectory(_p.StatsDir);

        var c = BackupConfig.LoadOrDefault(_p.ConfigFile);
        var err = Validate(c);
        if (err != null)
        {
            Log("ERROR: " + err);
            Syslog.Err("FATAL: " + err);
            WriteStatus(c, "failed", "", err);
            return err;
        }
        MarkStaleRuns(c.Target);
        RunBackup(c);
        return null;
    }

    // ============================================================ validate()

    private string? Validate(BackupConfig c)
    {
        if (!ToolExists("rsync"))
            return "rsync not found on this system - plugin requires rsync";

        _disks = EnumerateDisks();
        if (_disks.Count == 0)
            return "no data disks found under /mnt - is the array started? (override with ARRAYBACKUP_DISKS / ARRAYBACKUP_MNT)";

        if (!Directory.Exists(c.Target))
        {
            if (File.Exists(c.Target)) return "backup target path is not a directory: " + c.Target;
            return "backup target does not exist: " + c.Target + " (check the path in the plugin settings; mount it first)";
        }
        if (!IsMounted(c.Target))
            return "target is not a mount point: " + c.Target;

        if (EnginePaths.IsUnixish)
        {
            var rt = RealPath(c.Target) ?? c.Target;
            if (Regex.IsMatch(rt, "^/mnt/(disk[0-9]+|user|share)"))
                return "refusing to back up onto the array itself: " + rt;
        }

        try
        {
            using var w = File.Create(Path.Combine(c.Target, ".ab_write_test"));
        }
        catch
        {
            return "backup target is not writable (permissions/share read-only?): " + c.Target;
        }

        var t = Path.Combine(c.Target, $".ab_linktest.{Environment.ProcessId}");
        try
        {
            File.WriteAllText(t, "");
            CreateHardLink(t + ".2", t);
        }
        catch
        {
            return "target filesystem does not support hard links (use ext4/xfs/btrfs)";
        }
        finally
        {
            TryDeleteFile(t); TryDeleteFile(t + ".2");
        }

        if (c.RetentionMinFreeGb > 0)
        {
            var availKb = FreeKb(c.Target);
            if (availKb >= 0)
            {
                long needKb = (long)c.RetentionMinFreeGb * 1024 * 1024;
                if (availKb < needKb)
                    return $"not enough free space on {c.Target}: {availKb} KB available, {needKb} KB required";
            }
        }
        return null;
    }

    private static bool ToolExists(string name)
    {
        try
        {
            var psi = new ProcessStartInfo(name)
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            psi.ArgumentList.Add("--version");
            using var p = Process.Start(psi);
            p!.WaitForExit(5000);
            return p.ExitCode == 0;
        }
        catch { return false; }
    }

    private static bool IsMounted(string target)
    {
        if (!EnginePaths.IsUnixish) return true;
        try
        {
            var psi = new ProcessStartInfo("findmnt") { UseShellExecute = false, RedirectStandardOutput = true };
            psi.ArgumentList.Add("-T");
            psi.ArgumentList.Add(target);
            using var p = Process.Start(psi);
            p!.WaitForExit(5000);
            return p.ExitCode == 0;
        }
        catch { return true; } // findmnt nicht vorhanden -> nicht blockieren
    }

    private static double FreeKb(string target)
    {
        // wie engine.sh: df -Pk liefert die KB des echten Mounts (DriveInfo
        // wuerde auf Linux nur das Root-Volume messen); auf Windows DriveInfo.
        if (EnginePaths.IsUnixish)
        {
            try
            {
                var psi = new ProcessStartInfo("df") { UseShellExecute = false, RedirectStandardOutput = true };
                psi.ArgumentList.Add("-Pk");
                psi.ArgumentList.Add(target);
                using var p = Process.Start(psi);
                p!.WaitForExit(5000);
                var lines = (p.StandardOutput.ReadToEnd() ?? "").Split('\n');
                if (lines.Length >= 2)
                {
                    var cols = lines[^1].Split(' ', StringSplitOptions.RemoveEmptyEntries);
                    if (cols.Length >= 4 && double.TryParse(cols[3], out var kb)) return kb;
                }
            }
            catch { }
            return -1;
        }
        try
        {
            var root = Path.GetPathRoot(Path.GetFullPath(target));
            if (string.IsNullOrEmpty(root)) return -1;
            return new DriveInfo(root).AvailableFreeSpace / 1024.0;
        }
        catch { return -1; }
    }

    private List<string> EnumerateDisks()
    {
        var ov = Environment.GetEnvironmentVariable("ARRAYBACKUP_DISKS");
        if (!string.IsNullOrWhiteSpace(ov))
            return ov.Split([';', ':'], StringSplitOptions.RemoveEmptyEntries)
                     .Select(s => s.Trim()).Where(Directory.Exists).ToList();

        var mnt = Environment.GetEnvironmentVariable("ARRAYBACKUP_MNT")
                  ?? (EnginePaths.IsUnixish ? "/mnt" : Path.Combine("data", "mnt"));
        if (!Directory.Exists(mnt)) return new();
        return Directory.EnumerateDirectories(mnt)
                        .Where(d => Regex.IsMatch(Path.GetFileName(d), @"^disk\d+$"))
                        .OrderBy(d => d, StringComparer.Ordinal)
                        .ToList();
    }

    // ==================================================== status.json / logs

    private static string Fmt(DateTime t) => t.ToString("yyyy-MM-dd HH:mm:ss");
    private static string FmtNow() => Fmt(DateTime.Now);

    private void Log(string msg)
    {
        var line = $"[{FmtNow()}] {msg}";
        Console.WriteLine(line);
        try
        {
            lock (_logGate) File.AppendAllText(_p.EngineLog, line + "\n");
        }
        catch { }
    }

    /// <summary>Port von write_status(state, run_id, errmsg) aus engine.sh.</summary>
    private void WriteStatus(BackupConfig c, string state, string runId, string? errmsg = null)
    {
        var sb = new StringBuilder();
        sb.Append('{');
        sb.Append("\"state\":\"").Append(state).Append("\",");
        sb.Append("\"run_id\":\"").Append(runId).Append("\",");
        sb.Append("\"updated\":\"").Append(FmtNow()).Append("\",");
        sb.Append("\"dry_run\":").Append(c.DryRun ? "true" : "false");
        if (!string.IsNullOrEmpty(errmsg))
        {
            var clean = Regex.Replace(errmsg, @"[\r\n""\\]", " ");
            if (clean.Length > 500) clean = clean[..500];
            sb.Append(",\"error\":\"").Append(clean).Append('"');
        }
        sb.Append(",\"disks\":{");
        var parts = new List<string>();
        foreach (var d in _disks)
        {
            var name = Path.GetFileName(d);
            string pct = "", rate = "", eta = "";
            var logFile = Path.Combine(_p.ProgressDir, name + ".log");
            if (File.Exists(logFile))
            {
                var last = LastProgressLine(logFile);
                if (last != null)
                {
                    pct = Regex.Match(last, @"[0-9]*\.?[0-9]+%").Value.TrimEnd('%');
                    rate = Regex.Match(last, @"[0-9]+([.,][0-9]+)?\s*(kB|MB|GB|TB|B)/s").Value;
                    eta = Regex.Match(last, @"[0-9]+:[0-9]{2}(:[0-9]{2})?").Value;
                }
            }
            var exFile = Path.Combine(_p.StatsDir, name + ".exit");
            string ex = File.Exists(exFile) ? File.ReadAllText(exFile).Trim() : "";
            parts.Add($"\"{name}\":{{\"pct\":\"{pct}\",\"rate\":\"{rate}\",\"eta\":\"{eta}\",\"exit\":\"{ex}\"}}");
        }
        sb.Append(string.Join(",", parts));
        sb.Append("}}");

        var tmp = _p.StatusFile + ".tmp";
        File.WriteAllText(tmp, sb.ToString());
        File.Move(tmp, _p.StatusFile, overwrite: true);
    }

    /// <summary>
    /// Fortschritts-Parsing werte-basiert, NICHT feldposition-basiert: die
    /// Reihenfolge der Felder in der rsync-progress2-Zeile unterscheidet sich
    /// je nach rsync-Version (alt: "% rate eta", neu 3.2.3+: "bytes % eta rate").
    /// </summary>
    private static string? LastProgressLine(string logFile)
    {
        try
        {
            var text = File.ReadAllText(logFile).Replace('\r', '\n');
            var lines = text.Split('\n');
            for (int i = lines.Length - 1; i >= 0; i--)
                if (Regex.IsMatch(lines[i], @"[0-9]+%(\s|$)")) return lines[i];
        }
        catch { }
        return null;
    }

    // ==================================================== runs / resume / meta

    private void MarkStaleRuns(string target)
    {
        var runsDir = Path.Combine(target, "runs");
        if (!Directory.Exists(runsDir)) return;
        foreach (var dir in Directory.EnumerateDirectories(runsDir))
        {
            var metaFile = Path.Combine(dir, ".runmeta.json");
            if (!File.Exists(metaFile)) continue;
            try
            {
                var txt = File.ReadAllText(metaFile);
                if (txt.Contains("\"state\":\"running\""))
                {
                    File.WriteAllText(metaFile, txt.Replace("\"state\":\"running\"", "\"state\":\"aborted\""));
                    Log("marked stale run as aborted: " + Path.GetFileName(dir));
                }
            }
            catch { }
        }
    }

    /// <summary>
    /// Neuesten abgebrochenen Lauf finden (aborted/partial/failed oder ohne Meta =
    /// Crash) - dessen Verzeichnis wird fuer die Fortsetzung wiederverwendet.
    /// </summary>
    private string? FindResumableRun(string runsDir)
    {
        if (!Directory.Exists(runsDir)) return null;
        var names = Directory.EnumerateDirectories(runsDir)
                             .Select(Path.GetFileName)
                             .Where(n => n != null && n.StartsWith("r-"))
                             .Cast<string>()
                             .OrderByDescending(n => n, StringComparer.Ordinal);
        foreach (var r in names)
        {
            var metaFile = Path.Combine(runsDir, r, ".runmeta.json");
            if (!File.Exists(metaFile)) return r; // Crash/Reboot mitten im Lauf
            try
            {
                var st = Regex.Match(File.ReadAllText(metaFile), @"""state""\s*:\s*""([a-z]+)""").Groups[1].Value;
                if (st is "aborted" or "partial" or "failed") return r;
            }
            catch { return r; }
        }
        return null;
    }

    private string? MetaStarted(string runRoot)
    {
        try
        {
            var m = Regex.Match(File.ReadAllText(Path.Combine(runRoot, ".runmeta.json")),
                                @"""started""\s*:\s*""([^""]+)""");
            return m.Success ? m.Groups[1].Value : null;
        }
        catch { return null; }
    }

    // ============================================================ run_backup

    private void RunBackup(BackupConfig c)
    {
        var runId = "r-" + DateTime.Now.ToString("yyyyMMdd-HHmmss");
        var runsDir = Path.Combine(c.Target, "runs");
        var runRoot = Path.Combine(runsDir, runId);
        var startEpoch = DateTime.Now;
        string started;
        string latestAbs = "";
        string prevStarted = "";

        if (!c.DryRun && c.ResumeAborted)
        {
            var rid = FindResumableRun(runsDir);
            if (rid != null)
            {
                runId = rid;
                runRoot = Path.Combine(runsDir, runId);
                prevStarted = MetaStarted(runRoot) ?? "";
                Log($"resuming interrupted run {runId} - already copied files are skipped");
                Syslog.Err($"resuming interrupted run {runId} (Etappen-Fortsetzung aktiv)");
            }
        }

        Directory.CreateDirectory(runsDir);
        if (!c.DryRun) Directory.CreateDirectory(runRoot);

        var latestLink = Path.Combine(c.Target, "latest");
        if (Directory.Exists(latestLink))
            latestAbs = RealPath(latestLink) ?? "";

        started = prevStarted != "" ? prevStarted : FmtNow();
        WriteStatus(c, "running", runId);
        Log($"run {runId} started (disks: {_disks.Count}, dry_run={(c.DryRun ? 1 : 0)}, link-dest={(latestAbs != "" ? latestAbs : "none")})");

        var excludeFile = c.ExcludeFile ?? _p.ExcludeDefault;
        var completions = new List<Task>();

        foreach (var d in _disks)
        {
            if (c.MaxJobs > 0)
            {
                while (CountRunning(completions) >= c.MaxJobs) Thread.Sleep(1000);
            }

            var name = Path.GetFileName(d);
            var dest = Path.Combine(runRoot, name);
            var args = new List<string>
            {
                "-aHAX", "--numeric-ids", "--delete", "--stats", "--info=progress2", "--partial",
            };
            if (latestAbs != "" && Directory.Exists(Path.Combine(latestAbs, name)))
                args.Add("--link-dest=" + Path.Combine(latestAbs, name));
            if (File.Exists(excludeFile)) args.Add("--exclude-from=" + excludeFile);
            if (c.BwlimitKbps > 0) args.Add("--bwlimit=" + c.BwlimitKbps);
            if (c.DryRun) args.Add("-n");
            args.Add(d.TrimEnd('/', '\\') + "/");
            args.Add(dest.TrimEnd('/', '\\') + "/");

            completions.Add(StartRsync(args, Path.Combine(_p.ProgressDir, name + ".log"),
                                       Path.Combine(_p.StatsDir, name + ".exit")));
        }

        // Ueberwachungsloop wie engine.sh: stop.flag prüfen, Status aktualisieren
        while (true)
        {
            if (File.Exists(_p.StopFlag)) KillAll();
            WriteStatus(c, "running", runId);
            if (completions.All(t => t.IsCompleted)) break;
            Thread.Sleep(2000);
        }
        Task.WhenAll(completions).GetAwaiter().GetResult();

        string state = "success";
        var failDetail = new StringBuilder();
        foreach (var d in _disks)
        {
            var name = Path.GetFileName(d);
            var ecFile = Path.Combine(_p.StatsDir, name + ".exit");
            int ec = File.Exists(ecFile) && int.TryParse(File.ReadAllText(ecFile).Trim(), out var v) ? v : 1;
            if (ec != 0 && ec != 24)
            {
                state = "partial";
                var errline = ErrorLines(Path.Combine(_p.ProgressDir, name + ".log"));
                Log($"ERROR disk {name}: rsync exit={ec} - {errline}");
                Syslog.Err($"run {runId}: {name} failed (rsync exit={ec}): {(errline != "" ? errline : "keine Logausgabe")}");
                failDetail.Append($" {name}(exit={ec}): {(errline != "" ? errline : "rsync exit " + ec)};");
            }
        }
        if (File.Exists(_p.StopFlag)) state = "aborted";

        if (c.DryRun)
        {
            WriteStatus(c, state, runId, failDetail.ToString());
            Log($"dry run {runId} finished with state={state} (nothing written)");
            if (state != "success") Syslog.Err($"dry run {runId} finished with state={state}");
            return;
        }

        long totalLogical = 0, totalDelta = 0;
        var disksMeta = new JsonObject();
        foreach (var d in _disks)
        {
            var name = Path.GetFileName(d);
            long logical = DirSize(Path.Combine(runRoot, name));
            long delta = 0;
            try
            {
                var m = Regex.Match(File.ReadAllText(Path.Combine(_p.ProgressDir, name + ".log")),
                                    @"Total transferred file size:\s*([0-9.,]+)");
                if (m.Success) long.TryParse(m.Groups[1].Value.Replace(",", ""), out delta);
            }
            catch { }
            totalLogical += logical;
            totalDelta += delta;
            var ec = TryInt(Path.Combine(_p.StatsDir, name + ".exit")) ?? 1;
            disksMeta[name] = new JsonObject
            {
                ["exit"] = ec,
                ["logical_bytes"] = logical,
                ["delta_bytes"] = delta,
            };
        }

        var meta = new JsonObject
        {
            ["run_id"] = runId,
            ["state"] = state,
            ["started"] = started,
            ["finished"] = FmtNow(),
            ["dry_run"] = false,
            ["total_logical_bytes"] = totalLogical,
            ["total_delta_bytes"] = totalDelta,
            ["disks"] = disksMeta,
        };
        File.WriteAllText(Path.Combine(runRoot, ".runmeta.json"), meta.ToJsonString());

        if (state == "success")
        {
            TrySymlink("runs/" + runId, latestLink);
            foreach (var d in _disks)
            {
                var name = Path.GetFileName(d);
                var pd = Path.Combine(c.Target, "perdisk", name);
                Directory.CreateDirectory(pd);
                TrySymlink("../../runs/" + runId + "/" + name, Path.Combine(pd, runId));
            }
            Prune(c, runId);
        }

        var dur = (int)(DateTime.Now - startEpoch).TotalSeconds;
        File.AppendAllText(_p.HistoryLog,
            $"{runId} {state} logical={totalLogical} delta={totalDelta} duration={dur}s\n");
        WriteStatus(c, state, runId, failDetail.Length > 0 ? failDetail.ToString() : null);
        if (state != "success")
            Syslog.Err($"run {runId} finished with state={state} (see {_p.EngineLog}){failDetail}");
        Log($"run {runId} finished: state={state} logical={totalLogical} delta={totalDelta} duration={dur}s");
    }

    private static int CountRunning(List<Task> ts) => ts.Count(t => !t.IsCompleted);

    private Task StartRsync(List<string> args, string logFile, string exitFile)
    {
        var psi = new ProcessStartInfo("rsync")
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);

        var proc = new Process { StartInfo = psi };
        proc.Start();
        lock (_rsyncProcs) _rsyncProcs.Add(proc);

        var fs = new FileStream(logFile, FileMode.Create, FileAccess.Write, FileShare.Read);
        var gate = new object();
        var pumpOut = PumpAsync(proc.StandardOutput.BaseStream, fs, gate);
        var pumpErr = PumpAsync(proc.StandardError.BaseStream, fs, gate);

        return Task.Run(async () =>
        {
            try { await proc.WaitForExitAsync(); }
            catch { }
            await Task.WhenAll(pumpOut, pumpErr);
            fs.Dispose();
            try { File.WriteAllText(exitFile, (proc.ExitCode).ToString()); }
            catch { }
            lock (_rsyncProcs) _rsyncProcs.Remove(proc);
        });
    }

    private static async Task PumpAsync(Stream src, FileStream dst, object gate)
    {
        var buf = new byte[8192];
        try
        {
            int n;
            while ((n = await src.ReadAsync(buf)) > 0)
                lock (gate) dst.Write(buf, 0, n);
        }
        catch { }
    }

    private static string ErrorLines(string logFile)
    {
        try
        {
            var text = File.ReadAllText(logFile).Replace('\r', '\n');
            var hits = Regex.Matches(text, @"(?im).*(rsync error|\bERROR\b|error:).*")
                             .Cast<Match>().Select(m => m.Value.Trim()).ToList();
            var picked = hits.Count > 0 ? hits.TakeLast(3) : text.Split('\n').TakeLast(2);
            return string.Join(" ", picked).Trim();
        }
        catch { return ""; }
    }

    private static long DirSize(string dir)
    {
        long sum = 0;
        try
        {
            foreach (var f in Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories))
                try { sum += new FileInfo(f).Length; } catch { }
        }
        catch { }
        return sum;
    }

    private static int? TryInt(string file)
    {
        try { return File.Exists(file) && int.TryParse(File.ReadAllText(file).Trim(), out var v) ? v : null; }
        catch { return null; }
    }

    // ================================================================ prune

    private void Prune(BackupConfig c, string runId)
    {
        var runsDir = Path.Combine(c.Target, "runs");
        var runs = Directory.Exists(runsDir)
            ? Directory.EnumerateDirectories(runsDir).Select(Path.GetFileName)
                       .Cast<string>().OrderBy(n => n, StringComparer.Ordinal).ToList()
            : new List<string>();

        int kept = 0;
        for (int i = runs.Count - 1; i >= 0; i--)
        {
            var r = runs[i];
            if (File.Exists(Path.Combine(runsDir, r, ".pinned"))) continue;
            kept++;
            if (kept > c.RetentionRuns) RemoveRun(runsDir, c.Target, r);
        }

        if (c.RetentionMinFreeGb > 0)
        {
            while (true)
            {
                var avail = FreeKb(c.Target);
                if (avail < 0 || avail >= (long)c.RetentionMinFreeGb * 1024 * 1024) break;
                var victim = runs.FirstOrDefault(r =>
                    Directory.Exists(Path.Combine(runsDir, r)) &&
                    !File.Exists(Path.Combine(runsDir, r, ".pinned")) &&
                    r != runId);
                if (victim == null) break;
                RemoveRun(runsDir, c.Target, victim);
                Log("disk space guard: removed run " + victim);
            }
        }
    }

    private static void RemoveRun(string runsDir, string target, string runId)
    {
        TryDeleteDir(Path.Combine(runsDir, runId));
        var pdRoot = Path.Combine(target, "perdisk");
        if (Directory.Exists(pdRoot))
        {
            foreach (var pd in Directory.EnumerateDirectories(pdRoot))
            {
                var link = Path.Combine(pd, runId);
                if (PathExistsOrLink(link)) TryDeleteFile(link);
            }
        }
    }

    // ===================================================== JSON-API helpers

    public List<(string Id, bool Pinned, bool IsLatest, JsonNode? Meta)> ListRuns(BackupConfig c)
    {
        var result = new List<(string, bool, bool, JsonNode?)>();
        var runsDir = Path.Combine(c.Target, "runs");
        if (!Directory.Exists(runsDir)) return result;
        var latest = RealPath(Path.Combine(c.Target, "latest")) ?? "";
        foreach (var dir in Directory.EnumerateDirectories(runsDir)
                                     .Where(d => Path.GetFileName(d).StartsWith("r-"))
                                     .OrderByDescending(d => d, StringComparer.Ordinal))
        {
            var id = Path.GetFileName(dir);
            JsonNode? meta = null;
            try
            {
                var mf = Path.Combine(dir, ".runmeta.json");
                if (File.Exists(mf)) meta = JsonNode.Parse(File.ReadAllText(mf));
            }
            catch { }
            result.Add((id,
                        File.Exists(Path.Combine(dir, ".pinned")),
                        latest != "" && RealPath(dir) == latest,
                        meta));
        }
        return result;
    }

    /// <summary>Port von safe_target_path() + ls aus ajax.php.</summary>
    public (bool Ok, List<Dictionary<string, object?>>? Entries, string? Error) ListDir(BackupConfig c, string rel)
    {
        var root = RealPath(c.Target);
        if (root == null) return (false, null, "backup target not mounted: " + c.Target);
        rel = rel.Replace('\\', '/').TrimStart('/');
        var test = rel == "" ? root : Path.Combine(root, rel);

        // tiefsten existierenden Vorfahr realpfaden (Symlink-Escape-Schutz)
        var dir = test;
        while (dir != null && !Directory.Exists(dir) && !File.Exists(dir)) dir = Path.GetDirectoryName(dir);
        if (dir == null) return (false, null, "invalid path");
        var real = RealPath(dir);
        if (real == null) return (false, null, "invalid path");
        var full = Path.GetFullPath(Path.Combine(real, Path.GetFileName(test)));
        if (full != root && !full.StartsWith(root + Path.DirectorySeparatorChar))
            return (false, null, "invalid path");
        if (!Directory.Exists(full)) return (false, null, "invalid path");

        var entries = new List<Dictionary<string, object?>>();
        foreach (var e in Directory.EnumerateFileSystemEntries(full))
        {
            var isDir = Directory.Exists(e);
            long? size = null; long mtime = 0;
            try
            {
                var fi = new FileInfo(e);
                if (!isDir) size = fi.Length;
                mtime = ((DateTimeOffset)(isDir ? Directory.GetLastWriteTime(e) : fi.LastWriteTime)).ToUnixTimeSeconds();
            }
            catch { }
            entries.Add(new Dictionary<string, object?>
            {
                ["name"] = Path.GetFileName(e),
                ["dir"] = isDir,
                ["size"] = size,
                ["mtime"] = mtime,
            });
        }
        entries.Sort((a, b) =>
        {
            bool ad = (bool)a["dir"]!, bd = (bool)b["dir"]!;
            if (ad != bd) return bd.CompareTo(ad); // dirs first
            return string.Compare((string)a["name"]!, (string)b["name"]!, StringComparison.Ordinal);
        });
        return (true, entries, null);
    }

    public (bool Ok, bool Pinned, string? Error) PinRun(BackupConfig c, string id)
    {
        id = Regex.Replace(id, @"[^a-zA-Z0-9\-]", "");
        var dir = Path.Combine(c.Target, "runs", id);
        if (!Directory.Exists(dir)) return (false, false, "run not found");
        var pin = Path.Combine(dir, ".pinned");
        if (File.Exists(pin)) TryDeleteFile(pin); else File.WriteAllText(pin, "");
        return (true, File.Exists(pin), null);
    }

    public (bool Ok, string? Error) DeleteRun(BackupConfig c, string id)
    {
        id = Regex.Replace(id, @"[^a-zA-Z0-9\-]", "");
        var target = c.Target.TrimEnd('/');
        var dir = Path.Combine(target, "runs", id);
        if (!Directory.Exists(dir)) return (false, "run not found");
        if (IsRunning) return (false, "cannot delete while a backup is running");

        var latestLink = Path.Combine(target, "latest");
        bool isLatest = Directory.Exists(latestLink) && RealPath(latestLink) == RealPath(dir);
        RemoveRun(Path.Combine(target, "runs"), target, id);
        if (isLatest)
        {
            TryDeleteFile(latestLink);
            var newest = ListRuns(c).FirstOrDefault(r =>
                r.Meta?["state"]?.GetValue<string>() == "success");
            if (newest.Id != null) TrySymlink("runs/" + newest.Id, latestLink);
        }
        return (true, null);
    }

    public JsonNode? ReadStatus()
    {
        try
        {
            return File.Exists(_p.StatusFile) ? JsonNode.Parse(File.ReadAllText(_p.StatusFile)) : null;
        }
        catch { return null; }
    }

    public bool EngineRunningExternal()
    {
        if (IsRunning) return true;
        try
        {
            if (!File.Exists(_p.PidFile)) return false;
            var pid = int.Parse(File.ReadAllText(_p.PidFile).Trim());
            try { Process.GetProcessById(pid); return true; }
            catch { return false; }
        }
        catch { return false; }
    }

    // ============================================================ filesystem

    /// <summary>Loest Symlink-Ketten stueckweise auf (realpath-Aequivalent).</summary>
    private static string? RealPath(string path)
    {
        try
        {
            var cur = Path.GetFullPath(path);
            for (int i = 0; i < 40; i++)
            {
                FileSystemInfo fsi = Directory.Exists(cur) ? new DirectoryInfo(cur) : (FileSystemInfo)new FileInfo(cur);
                if (fsi.LinkTarget == null) break;
                cur = Path.IsPathRooted(fsi.LinkTarget)
                    ? fsi.LinkTarget
                    : Path.GetFullPath(Path.Combine(fsi.FullName, "..", fsi.LinkTarget));
                if (!Directory.Exists(cur) && !File.Exists(cur)) return null;
            }
            return Path.GetFullPath(cur);
        }
        catch { return null; }
    }

    private static void TrySymlink(string target, string linkPath)
    {
        try
        {
            if (PathExistsOrLink(linkPath)) TryDeleteFile(linkPath);
            Directory.CreateSymbolicLink(linkPath, target);
        }
        catch
        {
            try { Directory.CreateSymbolicLink(linkPath, target); } catch { }
        }
    }

    /// <summary>Existiert der Pfad als Datei/Verzeichnis ODER als (defekter) Symlink?</summary>
    private static bool PathExistsOrLink(string path)
    {
        if (File.Exists(path) || Directory.Exists(path)) return true;
        try { return new FileInfo(path).LinkTarget != null; } catch { return false; }
    }

    /// <summary>File.CreateHardLink gibt es erst ab .NET 9 - hier P/Invoke bzw. 'ln'.</summary>
    private static void CreateHardLink(string newLink, string targetFile)
    {
        if (OperatingSystem.IsWindows())
        {
            if (!CreateHardLinkW(newLink, targetFile, IntPtr.Zero))
                throw new IOException("CreateHardLink failed: " +
                    new System.ComponentModel.Win32Exception(
                        System.Runtime.InteropServices.Marshal.GetLastWin32Error()).Message);
            return;
        }
        var psi = new ProcessStartInfo("ln") { UseShellExecute = false, RedirectStandardError = true };
        psi.ArgumentList.Add(targetFile);
        psi.ArgumentList.Add(newLink);
        using var p = Process.Start(psi);
        p!.WaitForExit(5000);
        if (p.ExitCode != 0) throw new IOException("ln exited with " + p.ExitCode);
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern bool CreateHardLinkW(string lpFileName, string lpExistingFileName, IntPtr lpSecurityAttributes);

    private static void TryDeleteFile(string path)
    {
        try
        {
            if (File.Exists(path)) File.Delete(path);
            else if (Directory.Exists(path) && new DirectoryInfo(path).LinkTarget != null) Directory.Delete(path);
        }
        catch { }
    }

    private static void TryDeleteDir(string path)
    {
        try { if (Directory.Exists(path)) Directory.Delete(path, true); } catch { }
    }
}

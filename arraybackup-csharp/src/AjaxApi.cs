using System.Text.Json.Nodes;

namespace ArrayBackup;

/// <summary>
/// Port von ajax.php: identische JSON-Actions (config-get, config-save, start,
/// stop, status, runs, ls, pin, delete-run) unter /ajax?action=...
/// Antwortformat wie im Original: {"ok":true/false,...}.
///
/// CSRF: das Unraid-Original wird von emhttp geschuetzt (POSTs ohne gueltigen
/// csrf_token verwirft emhttp, BEVOR ajax.php laeuft). Ein Standalone-Daemon
/// hat keinen emhttp-Wrapper - stattdessen derselbe Mechanismus nachgebaut:
/// der Client holt sich den Token ueber GET /csrf und sendet ihn in jedem POST.
/// </summary>
public static class AjaxApi
{
    public static void Map(WebApplication app, Engine engine)
    {
        app.MapGet("/csrf", () => Results.Json(new
        {
            ok = true,
            csrf_token = Csrf.Token(),
        }));

        app.Map("/ajax", (HttpContext ctx) =>
        {
            // Request.Form nur bei POST anfassen (GET hat keinen Form-Content-Type)
            IFormCollection? form = HttpMethods.IsPost(ctx.Request.Method) ? ctx.Request.Form : null;
            var action = ctx.Request.Query["action"].ToString();
            if (string.IsNullOrEmpty(action) && form != null)
                action = form["action"].ToString();

            var c = BackupConfig.LoadOrDefault(engine.Paths.ConfigFile);

            // POSTs ohne gueltigen Token ablehnen (Analogie zum emhttp-Check)
            if (form != null && !Csrf.Valid(form["csrf_token"].ToString()))
                return Json(new { ok = false, error = "invalid csrf token - reload the page" });

            switch (action)
            {
                case "config-get":
                    var efGet = c.ExcludeFile ?? engine.Paths.ExcludeDefault;
                    var cfgObj = new JsonObject
                    {
                        ["target"] = c.Target,
                        ["retention_runs"] = c.RetentionRuns,
                        ["retention_min_free_gb"] = c.RetentionMinFreeGb,
                        ["max_jobs"] = c.MaxJobs,
                        ["bwlimit_kbps"] = c.BwlimitKbps,
                        ["dry_run"] = c.DryRun,
                        ["resume_aborted"] = c.ResumeAborted,
                        ["exclude_file"] = c.ExcludeFile,
                        ["schedule_enabled"] = c.ScheduleEnabled,
                        ["schedule_cron"] = c.ScheduleCron,
                        ["excludes"] = File.Exists(efGet) ? File.ReadAllText(efGet) : "",
                    };
                    return Json(new { ok = true, config = cfgObj });

                case "config-save":
                    var f = form!;
                    if (f.ContainsKey("target"))          c.Target = f["target"].ToString().Trim();
                    if (f.ContainsKey("schedule_cron"))   c.ScheduleCron = f["schedule_cron"].ToString().Trim();
                    if (f.ContainsKey("exclude_file"))    c.ExcludeFile = f["exclude_file"].ToString().Trim();
                    if (f.ContainsKey("retention_runs"))        c.RetentionRuns = Math.Max(1, ParseInt(f["retention_runs"]));
                    if (f.ContainsKey("retention_min_free_gb")) c.RetentionMinFreeGb = Math.Max(0, ParseInt(f["retention_min_free_gb"]));
                    if (f.ContainsKey("max_jobs"))              c.MaxJobs = Math.Max(0, ParseInt(f["max_jobs"]));
                    if (f.ContainsKey("bwlimit_kbps"))          c.BwlimitKbps = Math.Max(0, ParseInt(f["bwlimit_kbps"]));
                    c.DryRun = On(f["dry_run"]);
                    c.ResumeAborted = f["resume_aborted"].Count == 0 || On(f["resume_aborted"]);
                    c.ScheduleEnabled = On(f["schedule_enabled"]);
                    c.ExcludeFile = string.IsNullOrWhiteSpace(f["exclude_file"].ToString())
                        ? engine.Paths.ExcludeDefault : f["exclude_file"].ToString().Trim();
                    Directory.CreateDirectory(engine.Paths.ConfigDir);
                    if (!string.IsNullOrEmpty(f["excludes"].ToString()))
                    {
                        var dir = Path.GetDirectoryName(c.ExcludeFile);
                        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                        File.WriteAllText(c.ExcludeFile, f["excludes"].ToString().Replace("\r\n", "\n"));
                    }
                    if (!File.Exists(c.ExcludeFile)) File.WriteAllText(c.ExcludeFile, "");
                    c.Save(engine.Paths.ConfigFile);
                    return Json(new { ok = true });

                case "start":
                    var err = engine.StartBackground();
                    return err == null ? Json(new { ok = true }) : Json(new { ok = false, error = err });

                case "stop":
                    var serr = engine.Stop();
                    return serr == null ? Json(new { ok = true }) : Json(new { ok = false, error = serr });

                case "status":
                    var s = engine.ReadStatus() ?? new JsonObject();
                    s["engine_running"] = engine.EngineRunningExternal();
                    return Json(new { ok = true, status = s });

                case "runs":
                    if (!Directory.Exists(c.Target))
                        return Json(new { ok = false, error = "backup target not mounted: " + c.Target });
                    var runs = engine.ListRuns(c).Select(r => new
                    {
                        id = r.Id,
                        pinned = r.Pinned,
                        is_latest = r.IsLatest,
                        meta = r.Meta,
                    });
                    return Json(new { ok = true, runs, target = c.Target });

                case "ls":
                    var rel = ctx.Request.Query["path"].ToString();
                    if (string.IsNullOrEmpty(rel) && form != null && form.ContainsKey("path"))
                        rel = form["path"].ToString();
                    var (lsOk, entries, lsErr) = engine.ListDir(c, rel);
                    return lsOk ? Json(new { ok = true, path = rel, entries })
                                : Json(new { ok = false, error = lsErr });

                case "pin":
                    var (pOk, pinned, pErr) = engine.PinRun(c, form?["run"].ToString() ?? "");
                    return pOk ? Json(new { ok = true, pinned }) : Json(new { ok = false, error = pErr });

                case "delete-run":
                    var (dOk, dErr) = engine.DeleteRun(c, form?["run"].ToString() ?? "");
                    return dOk ? Json(new { ok = true }) : Json(new { ok = false, error = dErr });

                default:
                    return Json(new { ok = false, error = "unknown action" });
            }
        });
    }

    private static IResult Json(object o) => Results.Json(o);

    private static int ParseInt(string? s) => int.TryParse(s, out var v) ? v : 0;
    private static bool On(string? v) => v is "1" or "true" or "on" or "yes";
}

/// <summary>
/// Einfacher Session-CSRF-Token (HMAC ueber einen pro-Start generierten
/// Secrets). Standalone-Ersatz fuer den emhttp-csrf_token.
/// </summary>
internal static class Csrf
{
    private static readonly byte[] Secret = System.Security.Cryptography.RandomNumberGenerator.GetBytes(32);

    public static string Token()
    {
        using var h = new System.Security.Cryptography.HMACSHA256(Secret);
        return Convert.ToHexString(h.ComputeHash(System.Text.Encoding.UTF8.GetBytes("arraybackup-session")));
    }

    public static bool Valid(string? token) =>
        !string.IsNullOrEmpty(token) && token.Length == 64 &&
        string.Equals(token, Token(), StringComparison.OrdinalIgnoreCase);
}

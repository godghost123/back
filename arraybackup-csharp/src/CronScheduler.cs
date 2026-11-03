using System.Text.RegularExpressions;

namespace ArrayBackup;

/// <summary>
/// Ersatz fuer den Cron-Mechanismus des Originals (arraybackup.cron + update_cron):
/// der Scheduler prueft alle 30 s, ob der konfigurierte 5-Felder-Cron-Ausdruck
/// auf die aktuelle Minute passt, und startet dann einen Backup-Lauf.
/// </summary>
public sealed class CronScheduler
{
    private readonly Engine _engine;
    private Timer? _timer;
    private string _lastFiredMinute = "";

    public CronScheduler(Engine engine) => _engine = engine;

    public void Start()
    {
        _timer = new Timer(_ => Tick(), null,
            TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(30));
    }

    private void Tick()
    {
        try
        {
            var c = BackupConfig.LoadOrDefault(_engine.Paths.ConfigFile);
            if (!c.ScheduleEnabled) return;
            var now = DateTime.Now;
            if (!CronMatch(c.ScheduleCron, now)) return;

            var minuteKey = now.ToString("yyyyMMddHHmm");
            if (minuteKey == _lastFiredMinute) return;      // pro Minute nur einmal
            _lastFiredMinute = minuteKey;

            if (_engine.IsRunning || _engine.EngineRunningExternal()) return;
            Console.WriteLine($"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] cron: starting scheduled run ({c.ScheduleCron})");
            _engine.StartBackground();
        }
        catch (Exception e)
        {
            Console.Error.WriteLine("scheduler error: " + e.Message);
        }
    }

    // ------------------------------------------------------- cron matching

    /// <summary>
    /// 5-Felder-Cron ("min hour dom mon dow"), wie vom Original-Plugin erlaubt
    /// (nur Ziffern, * / , - und Leerzeichen je Feld). Unterstuetzt *, a, a-b,
    /// a/n, a-b/n, */n und Listen.
    /// </summary>
    public static bool CronMatch(string expr, DateTime t)
    {
        expr = expr.Trim();
        if (!RegexOk(expr)) return false;
        var f = expr.Split([' ', '\t'], StringSplitOptions.RemoveEmptyEntries);
        if (f.Length != 5) return false;
        return Field(f[0], t.Minute, 0, 59)
            && Field(f[1], t.Hour, 0, 23)
            && Field(f[2], t.Day, 1, 31)
            && Field(f[3], t.Month, 1, 12)
            && Field(f[4], (int)t.DayOfWeek, 0, 7);
    }

    private static bool RegexOk(string expr) =>
        Regex.IsMatch(expr, @"^[\d*\/,\-]+( +[\d*\/,\-]+){4}$");

    private static bool Field(string spec, int value, int min, int max)
    {
        if (spec == "*") return true;
        foreach (var part in spec.Split(','))
        {
            var p = part.Trim();
            int step = 1;
            int lo = min, hi = max;
            var slash = p.Split('/');
            if (slash.Length == 2 && !int.TryParse(slash[1], out step)) continue;
            var range = slash[0];
            if (range == "*")
            {
                lo = min; hi = max;
            }
            else if (range.Contains('-'))
            {
                var ab = range.Split('-', 2);
                if (!int.TryParse(ab[0], out lo) || !int.TryParse(ab[1], out hi)) continue;
            }
            else
            {
                if (!int.TryParse(range, out lo)) continue;
                hi = step > 1 ? max : lo;
            }
            if (max == 7 && (lo == 7 || hi == 7)) // Sonntag auch als 7
            {
                if (value == 0 && (lo == 7 || hi == 7)) return true;
                if (lo == 7) lo = 0;
                if (hi == 7) hi = 0;
            }
            if (value >= lo && value <= hi && (value - lo) % Math.Max(1, step) == 0)
                return true;
        }
        return false;
    }
}

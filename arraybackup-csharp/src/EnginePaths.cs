namespace ArrayBackup;

/// <summary>
/// Alle Pfade des Plugins. Auf Linux/Unraid die gleichen Orte wie das Original-PLG
/// (/boot/config/plugins/arraybackup, /var/run/arraybackup); sonst lokale
/// data/-Verzeichnisse, damit es auch ohne Unraid laeuft.
/// </summary>
public sealed class EnginePaths
{
    public required string ConfigDir { get; init; }
    public required string RunDir { get; init; }

    public string ConfigFile    => Path.Combine(ConfigDir, "config.json");
    public string ExcludeDefault=> Path.Combine(ConfigDir, "excludes.txt");
    public string LogDir        => Path.Combine(ConfigDir, "logs");
    public string EngineLog     => Path.Combine(LogDir, "engine.log");
    public string HistoryLog    => Path.Combine(LogDir, "history.log");
    public string StatusFile    => Path.Combine(RunDir, "status.json");
    public string LockFile      => Path.Combine(RunDir, "engine.lock");
    public string StopFlag      => Path.Combine(RunDir, "stop.flag");
    public string PidFile       => Path.Combine(RunDir, "engine.pid");
    public string ProgressDir   => Path.Combine(RunDir, "progress");
    public string StatsDir      => Path.Combine(RunDir, "stats");

    public static bool IsUnixish =>
        OperatingSystem.IsLinux() || OperatingSystem.IsMacOS() || OperatingSystem.IsFreeBSD();

    public static EnginePaths Default()
    {
        var configDir = Environment.GetEnvironmentVariable("ARRAYBACKUP_CONFIG_DIR")
            ?? (IsUnixish ? "/boot/config/plugins/arraybackup" : Path.Combine("data", "arraybackup"));
        var runDir = Environment.GetEnvironmentVariable("ARRAYBACKUP_RUN_DIR")
            ?? (IsUnixish ? "/var/run/arraybackup" : Path.Combine(configDir, "run"));
        // Direkt konstruieren - Create() aufrufen waere eine Endlosrekursion
        // (Create -> Default -> Create -> ...) und fuehrt zu Stack Overflow.
        return new EnginePaths { ConfigDir = configDir, RunDir = runDir };
    }

    public static EnginePaths Create(string? configDir, string? runDir)
    {
        if (configDir != null && runDir != null)
            return new EnginePaths { ConfigDir = configDir, RunDir = runDir };
        var d = Default();
        return new EnginePaths
        {
            ConfigDir = configDir ?? d.ConfigDir,
            RunDir    = runDir    ?? d.RunDir,
        };
    }
}

using System.Text.Json;
using System.Text.Json.Serialization;

namespace ArrayBackup;

/// <summary>
/// Port von load_config() aus ajax.php / engine.sh - identische Schluessel
/// wie config.json des Originalplugins.
/// </summary>
public sealed class BackupConfig
{
    [JsonPropertyName("target")]                public string Target          { get; set; } = "/mnt/backup";
    [JsonPropertyName("retention_runs")]        public int RetentionRuns      { get; set; } = 14;
    [JsonPropertyName("retention_min_free_gb")] public int RetentionMinFreeGb { get; set; } = 500;
    [JsonPropertyName("max_jobs")]              public int MaxJobs            { get; set; } = 0;
    [JsonPropertyName("bwlimit_kbps")]          public int BwlimitKbps        { get; set; } = 0;
    [JsonPropertyName("dry_run")]               public bool DryRun            { get; set; } = false;
    [JsonPropertyName("resume_aborted")]        public bool ResumeAborted     { get; set; } = true;
    [JsonPropertyName("exclude_file")]          public string? ExcludeFile    { get; set; }
    [JsonPropertyName("schedule_enabled")]      public bool ScheduleEnabled   { get; set; } = false;
    [JsonPropertyName("schedule_cron")]         public string ScheduleCron    { get; set; } = "0 2 * * 7";

    private static readonly JsonSerializerOptions Indented = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static BackupConfig LoadOrDefault(string file)
    {
        if (!File.Exists(file)) return new BackupConfig();
        try
        {
            return JsonSerializer.Deserialize<BackupConfig>(File.ReadAllText(file), Indented)
                   ?? new BackupConfig();
        }
        catch
        {
            return new BackupConfig();
        }
    }

    public void Save(string file)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, JsonSerializer.Serialize(this, Indented));
    }
}

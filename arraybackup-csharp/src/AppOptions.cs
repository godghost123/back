namespace ArrayBackup;

public sealed class AppOptions
{
    public string Command { get; private set; } = "serve";
    public int Port { get; private set; } = 8088;
    public bool Scheduler { get; private set; } = true;
    public EnginePaths Paths { get; private set; } = EnginePaths.Default();

    public static AppOptions Parse(string[] args)
    {
        var o = new AppOptions();
        string? configDir = null, runDir = null;

        var rest = new List<string>();
        for (int i = 0; i < args.Length; i++)
        {
            var a = args[i];
            switch (a)
            {
                case "--port":
                    o.Port = int.Parse(args[++i]);
                    break;
                case "--config":
                    configDir = args[++i];
                    break;
                case "--run":
                    runDir = args[++i];
                    break;
                case "--no-scheduler":
                    o.Scheduler = false;
                    break;
                default:
                    rest.Add(a);
                    break;
            }
        }
        if (rest.Count > 0) o.Command = rest[0];
        if (configDir != null || runDir != null)
            o.Paths = EnginePaths.Create(configDir, runDir);
        return o;
    }
}

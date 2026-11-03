using ArrayBackup;

// ArrayBackup (C#-Port des unRAID-ArrayBackup-Plugins)
// Befehle:
//   ArrayBackup                     -> Daemon: WebUI + API + Scheduler (Default)
//   ArrayBackup serve --port 8088   -> dito, explizit
//   ArrayBackup run-once            -> genau ein Backup-Durchlauf, dann Exit
//   ArrayBackup stop                -> Stop-Flag in ein laufendes Daemon-Verzeichnis schreiben

var opt = AppOptions.Parse(args);
var engine = new Engine(opt.Paths);

if (string.Equals(opt.Command, "stop", StringComparison.OrdinalIgnoreCase))
{
    engine.RequestStopExternal();
    return 0;
}

if (string.Equals(opt.Command, "run-once", StringComparison.OrdinalIgnoreCase))
{
    var err = engine.RunOnceBlocking();
    if (err != null)
    {
        Console.Error.WriteLine("ERROR: " + err);
        return 1;
    }
    return 0;
}

var scheduler = new CronScheduler(engine);
if (opt.Scheduler) scheduler.Start();

var builder = WebApplication.CreateBuilder(new WebApplicationOptions
{
    Args = args,
    ContentRootPath = AppContext.BaseDirectory,
});
builder.Logging.ClearProviders();
builder.Logging.AddSimpleConsole(o => o.SingleLine = true);
builder.WebHost.UseUrls($"http://*:{opt.Port}");
var app = builder.Build();

AjaxApi.Map(app, engine);

// Statische Dateien: wwwroot relativ zum Arbeitsverzeichnis ODER neben der DLL
var staticRoot = new[]
{
    Path.Combine(Directory.GetCurrentDirectory(), "wwwroot"),
    Path.Combine(AppContext.BaseDirectory, "wwwroot"),
    Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "wwwroot"), // Entwicklung
}
.Select(p => Path.GetFullPath(p))
.FirstOrDefault(Directory.Exists) ?? Path.Combine(AppContext.BaseDirectory, "wwwroot");
Directory.CreateDirectory(staticRoot);
var fileProvider = new Microsoft.Extensions.FileProviders.PhysicalFileProvider(staticRoot);
app.UseDefaultFiles(new Microsoft.AspNetCore.Builder.DefaultFilesOptions { FileProvider = fileProvider });
app.UseStaticFiles(new StaticFileOptions { FileProvider = fileProvider });

Console.WriteLine($"arraybackup (C#) - WebUI: http://localhost:{opt.Port}  (API: /ajax)");
app.Run();
return 0;

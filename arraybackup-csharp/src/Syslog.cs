using System.Net.Sockets;
using System.Text;

namespace ArrayBackup;

/// <summary>
/// Port von syslog_err() aus engine.sh: Fehler nach moeglichkeit direkt ins
/// Syslog (AF_UNIX-Socket /dev/log, PRI daemon.err=27), sonst ueber das
/// "logger"-Kommando, sonst still ignorieren (Fail-open).
/// </summary>
public static class Syslog
{
    public static void Err(string msg)
    {
        var line = "arraybackup: " + msg;

        if (EnginePaths.IsUnixish)
        {
            try
            {
                using var s = new Socket(AddressFamily.Unix, SocketType.Dgram, ProtocolType.Unspecified);
                s.Connect(new UnixDomainSocketEndPoint("/dev/log"));
                s.Send(Encoding.UTF8.GetBytes("<27>" + line + "\n"));
                return;
            }
            catch { /* socket nicht verfuegbar -> fallback */ }
        }

        try
        {
            var psi = new System.Diagnostics.ProcessStartInfo("logger") { UseShellExecute = false };
            psi.ArgumentList.Add("-t");
            psi.ArgumentList.Add("arraybackup");
            psi.ArgumentList.Add(line);
            System.Diagnostics.Process.Start(psi)?.WaitForExit(3000);
        }
        catch { /* kein logger vorhanden -> ignorieren */ }
    }
}

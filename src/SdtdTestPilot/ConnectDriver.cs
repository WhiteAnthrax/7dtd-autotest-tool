#if TESTPILOT_ENABLED
using System.Collections;

namespace SdtdTestPilot;

// Drives InviteManager.HandleIpPortInvite(ip, port, password, onFinished) - the same public,
// non-reflection API the game uses for "join by IP:port" invites (e.g. from Discord). This is
// the entire reason a headless test client works without touching AutomationRunner, which is
// deliberately disabled ("Disabled for this build type.") in shipped builds.
internal static class ConnectDriver
{
    public static void Start(TestPilotOptions options)
    {
        ThreadManager.StartCoroutine(Run(options));
    }

    private static IEnumerator Run(TestPilotOptions options)
    {
        Log.Info($"Connecting to {options.Ip}:{options.Port}...");

        bool? accepted = null;
        yield return InviteManager.HandleIpPortInvite(options.Ip, options.Port, options.Password, result => accepted = result);

        if (accepted != true)
        {
            Log.Error("Connect request was not accepted (invalid ip/port, or the invite handler rejected it).");
            yield break;
        }

        yield return WorldReadyWait.Wait(options.ReadyTimeoutSeconds, options);
    }
}
#endif

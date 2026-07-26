#if TESTPILOT_ENABLED
using System.Collections;

namespace SdtdTestPilot;

// Local-only mode: loads/hosts a world without any remote server, so this mod is also useful
// when there is no Docker/dedicated server to connect to. Mirrors the LoadGame step pattern
// seen in TFP's internal AutomationRunner (itself disabled in shipped builds) and the
// quickContinue() path XUiC_MainMenu uses for its own "continue last game" flow.
internal static class HostLoadDriver
{
    public static void Start(TestPilotOptions options)
    {
        ThreadManager.StartCoroutine(Run(options));
    }

    private static IEnumerator Run(TestPilotOptions options)
    {
        if (GameManager.Instance != null && GameManager.Instance.World != null)
        {
            Log.Info("A world is already loaded; skipping hostload and waiting for it to be ready.");
            yield return WorldReadyWait.Wait(options.ReadyTimeoutSeconds, options);
            yield break;
        }

        Log.Info($"Hosting local world '{options.World}' as game '{options.GameName}'...");

        GamePrefs.Set(EnumGamePrefs.GameWorld, options.World);
        GamePrefs.Set(EnumGamePrefs.GameName, options.GameName);
        GamePrefs.Instance.Load(GameIO.GetSaveGameDir() + "/gameOptions.sdf");
        // Server-side world creation (GameManager.startGameCo) only opens
        // XUiC_SpawnSelectionWindow and waits on canSpawnPlayer when this is false. Setting it
        // (after Load, so a saved gameOptions.sdf value can't override it) avoids that prompt
        // entirely instead of having to drive its button from the outside.
        GamePrefs.Set(EnumGamePrefs.SkipSpawnButton, true);

        NetworkConnectionError result = SingletonMonoBehaviour<ConnectionManager>.Instance.StartServers(
            GamePrefs.GetString(EnumGamePrefs.ServerPassword), _offline: false);
        if (result != NetworkConnectionError.NoError)
        {
            Log.Error("StartServers failed: " + result);
            yield break;
        }

        yield return WorldReadyWait.Wait(options.ReadyTimeoutSeconds, options);
    }
}
#endif

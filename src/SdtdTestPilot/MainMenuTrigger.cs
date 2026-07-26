#if TESTPILOT_ENABLED
using System.Threading;

namespace SdtdTestPilot;

// ModEvents.MainMenuOpened is the game's own extension point (XUiC_MainMenu.OnOpen invokes it
// after core menu setup), so this needs no Harmony patch. It fires every time the main menu
// opens (including after a disconnect), so a one-shot Interlocked guard plus the event's own
// FirstTimeOpen flag together make sure the driver only ever fires once per process.
internal static class MainMenuTrigger
{
    private static int _fired;

    public static void Register()
    {
        ModEvents.MainMenuOpened.RegisterHandler(OnMainMenuOpened);
    }

    private static void OnMainMenuOpened(ref ModEvents.SMainMenuOpenedData _data)
    {
        if (!_data.FirstTimeOpen)
        {
            return;
        }

        if (Interlocked.CompareExchange(ref _fired, 1, 0) != 0)
        {
            return;
        }

        TestPilotOptions options = TestPilotState.Options;
        switch (options.Mode)
        {
            case TestPilotMode.Connect:
                ConnectDriver.Start(options);
                break;
            case TestPilotMode.HostLoad:
                HostLoadDriver.Start(options);
                break;
        }
    }
}
#endif

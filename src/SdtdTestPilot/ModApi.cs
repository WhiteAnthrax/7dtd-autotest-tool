using System;
using UnityEngine;

namespace SdtdTestPilot;

// This class always exists (Debug and Release) so the mod loader always finds an IModApi
// implementation. Everything it can actually do lives behind TESTPILOT_ENABLED (Debug-only,
// see SdtdTestPilot.csproj) plus two further gates checked here: a marker file next to the
// DLL, and a required -testpilot.mode=... launch argument. A Release build, or a Debug build
// missing either gate, does nothing beyond this log line. See docs/HeadlessTestDriver.md.
public sealed class ModApi : IModApi
{
    public void InitMod(Mod _modInstance)
    {
#if TESTPILOT_ENABLED
        if (!TestPilotGate.IsEnabled())
        {
            Debug.Log("[SdtdTestPilot] disabled: create EnableTestPilot.txt next to the mod DLL to opt in.");
            return;
        }

        TestPilotOptions options = TestPilotOptionsParser.Parse(Environment.GetCommandLineArgs());
        if (options.Mode == TestPilotMode.None)
        {
            Debug.Log("[SdtdTestPilot] disabled: no valid -testpilot.mode=connect|hostload arguments supplied.");
            return;
        }

        TestPilotState.Options = options;
        MainMenuTrigger.Register();
        Debug.Log($"[SdtdTestPilot] Loaded, mode={options.Mode}, queue={options.QueueDir}.");
#else
        Debug.Log("[SdtdTestPilot] Release build: test driver code is not compiled in.");
#endif
    }
}

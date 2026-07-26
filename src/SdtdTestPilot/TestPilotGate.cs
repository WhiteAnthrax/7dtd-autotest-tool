#if TESTPILOT_ENABLED
using System.IO;
using System.Reflection;

namespace SdtdTestPilot;

// Opt-in gate so a Debug build never acts unless someone deliberately drops the marker file
// next to the mod DLL. Debug builds should not ship, but this is a second layer in case one
// ends up installed anyway. Mirrors VttTestHarnessGate in VisitedTraderTeleport/Testing.
internal static class TestPilotGate
{
    private const string MarkerFileName = "EnableTestPilot.txt";

    public static bool IsEnabled()
    {
        try
        {
            string dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            return !string.IsNullOrEmpty(dir) && File.Exists(Path.Combine(dir, MarkerFileName));
        }
        catch
        {
            return false;
        }
    }
}
#endif

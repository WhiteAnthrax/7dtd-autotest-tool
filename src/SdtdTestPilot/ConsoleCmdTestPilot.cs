#if TESTPILOT_ENABLED
using System.Collections.Generic;
using System.IO;

namespace SdtdTestPilot;

// A console command for driver-side actions that need to run inside the game process but are
// not tied to any one mod under test - currently just screenshots, which a driver script uses
// to capture evidence of what the client actually rendered.
//
// Same shape as VisitedTraderTeleport's ConsoleCmdVttTest: ConsoleCmdAbstract requires
// getCommands()/getDescription()/Execute(); getHelp() is optional.
internal sealed class ConsoleCmdTestPilot : ConsoleCmdAbstract
{
    public override string[] getCommands()
    {
        return new[] { "testpilot" };
    }

    public override string getDescription()
    {
        return "SdtdTestPilot driver commands (test builds only, requires EnableTestPilot.txt next to the mod DLL).";
    }

    public override string getHelp()
    {
        return "testpilot screenshot <absolute path without extension>";
    }

    public override void Execute(List<string> _params, CommandSenderInfo _senderInfo)
    {
        if (!TestPilotGate.IsEnabled())
        {
            SdtdConsole.Instance.Output("[testpilot] disabled: create EnableTestPilot.txt next to the mod DLL to opt in.");
            return;
        }

        string sub = _params.Count > 0 ? _params[0].ToLowerInvariant() : string.Empty;
        switch (sub)
        {
            case "screenshot":
                RunScreenshot(_params.Count > 1 ? _params[1] : null);
                break;
            default:
                Output("[testpilot] usage: testpilot screenshot <absolute path without extension>");
                break;
        }
    }

    // GameUtils.TakeScreenShot reads the framebuffer after WaitForEndOfFrame, so the capture
    // includes every open UI window - which is the whole point here. Confirmed against
    // Assembly-CSharp.dll (2026-07-29, 7DTD 3.1.0 b13): the override path must NOT carry an
    // extension, because the game appends ".jpg" itself (or ".tga" when asked for TGA).
    //
    // It runs as a coroutine, so the file does not exist yet when this command returns. The
    // emitted path is what the driver polls for.
    private static void RunScreenshot(string pathWithoutExtension)
    {
        if (string.IsNullOrEmpty(pathWithoutExtension))
        {
            EmitResult("screenshot", false, "an absolute path (without extension) is required");
            return;
        }

        if (pathWithoutExtension.EndsWith(".jpg") || pathWithoutExtension.EndsWith(".png"))
        {
            EmitResult("screenshot", false, "path must not carry an extension; the game appends .jpg itself");
            return;
        }

        try
        {
            string directory = Path.GetDirectoryName(pathWithoutExtension);
            if (!string.IsNullOrEmpty(directory) && !Directory.Exists(directory))
            {
                Directory.CreateDirectory(directory);
            }

            GameUtils.TakeScreenShot(GameUtils.EScreenshotMode.File, pathWithoutExtension);
            EmitResult("screenshot", true, pathWithoutExtension + ".jpg");
        }
        catch (System.Exception ex)
        {
            EmitResult("screenshot", false, ex.GetType().Name + ": " + ex.Message);
        }
    }

    // Mirrors VisitedTraderTeleport's VTT_TEST_RESULT marker so driver scripts parse both the
    // same way: one greppable single-line JSON result per command.
    private static void EmitResult(string action, bool ok, string detail)
    {
        Output($"TESTPILOT_RESULT {{\"action\":\"{action}\",\"ok\":{(ok ? "true" : "false")},\"detail\":\"{detail.Replace("\\", "\\\\").Replace("\"", "\\\"")}\"}}");
    }

    private static void Output(string message)
    {
        Log.Info(message);
        SdtdConsole.Instance.Output(message);
    }
}
#endif

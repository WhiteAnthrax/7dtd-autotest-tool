#if TESTPILOT_ENABLED
using System;
using System.Collections.Generic;

namespace SdtdTestPilot;

internal static class ConsoleCommandRunner
{
    // SdtdConsole.Instance.ExecuteSync(command, ClientInfo) runs the command line synchronously
    // on the local console (the same entry point Telnet/RCON drivers use) and returns its
    // output lines. Passing null for ClientInfo runs it as the local host, matching how
    // AutomationRunner's ConsoleCmd step and VisitedTraderTeleport's vtttest harness call it.
    public static bool TryExecute(string commandLine, out string output)
    {
        try
        {
            List<string> lines = SdtdConsole.Instance.ExecuteSync(commandLine, null);
            output = lines == null ? string.Empty : string.Join("\n", lines);
            return true;
        }
        catch (Exception ex)
        {
            output = "exception: " + ex.Message;
            return false;
        }
    }
}
#endif

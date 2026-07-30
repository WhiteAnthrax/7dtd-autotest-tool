#if TESTPILOT_ENABLED
using System.Collections.Generic;
using System.Text;

namespace SdtdTestPilot;

// Drives the game's own trader dialog window group so a driver script can walk a dialog and
// screenshot it.
//
// This lives here rather than in the mod under test on purpose. A mod's own test harness has
// to be compiled into that mod, which means it only exists in a Debug build - so it can never
// drive the Release build that actually ships. Everything below uses public game APIs only and
// knows nothing about any particular mod, so it drives whatever dialog the installed mods
// produce, Debug or Release. See docs/overview.md.
//
// Confirmed against Assembly-CSharp.dll (7DTD 3.1.0 b13 and the v2.6 line) by decompiling
// XUiC_DialogWindowGroup, XUiC_DialogResponseList, Dialog and DialogStatement:
//   - XUiC_DialogWindowGroup.OnOpen reads xui.Dialog.Respondent, so the respondent has to be
//     set before the window opens.
//   - 3.0's static XUiC_DialogWindowGroup.Open(xui) is just
//     windowManager.Open("dialog", _bModal: true), which exists on both lines, so that is what
//     is called here.
//   - a response click is exactly: dialog.SelectResponse(response, player) followed by
//     dialogWindowGroup.RefreshDialog().
//
// Only meaningful on a game client - a dedicated server has no LocalPlayerUI.
internal static class DialogDriver
{
    public static void Execute(List<string> args)
    {
        string sub = args.Count > 1 ? args[1].ToLowerInvariant() : string.Empty;

        switch (sub)
        {
            case "open":
                RunOpen(args.Count > 2 ? args[2] : null);
                break;
            case "dump":
                RunDump();
                break;
            case "select":
                RunSelect(args.Count > 2 ? args[2] : null);
                break;
            case "close":
                RunClose();
                break;
            default:
                Output("[testpilot] usage: testpilot dialog <open <entityId>|dump|select <responseId>|close>");
                break;
        }
    }

    private static void RunOpen(string entityIdArg)
    {
        if (!int.TryParse(entityIdArg, out int entityId))
        {
            EmitResult("dialog.open", false, "an entity id is required (see 'le')");
            return;
        }

        if (!(GameManager.Instance?.World?.GetEntity(entityId) is EntityTrader trader))
        {
            EmitResult("dialog.open", false, "no trader entity with that id");
            return;
        }

        LocalPlayerUI ui = LocalPlayerUI.GetUIForPrimaryPlayer();
        if (ui?.xui == null)
        {
            EmitResult("dialog.open", false, "no local player UI (dialog commands only run on a client)");
            return;
        }

        ui.xui.Dialog.Respondent = trader;
        ui.xui.playerUI.windowManager.Open("dialog", _bModal: true);
        EmitResult("dialog.open", true, trader.EntityName);
    }

    private static void RunDump()
    {
        if (!TryGetWindowGroup(out XUiC_DialogWindowGroup windowGroup, out string error))
        {
            EmitResult("dialog.dump", false, error);
            return;
        }

        Dialog dialog = windowGroup.CurrentDialog;
        DialogStatement statement = dialog?.CurrentStatement;
        if (statement == null)
        {
            EmitResult("dialog.dump", false, "dialog has no current statement");
            return;
        }

        // The logical side: every response the dialog produced, including any a mod's
        // GetResponses patch added.
        List<BaseResponseEntry> entries = statement.GetResponses();

        // The rendered side: how many of those the dialog skin actually has slots for. The
        // response list has a fixed number of XUiC_DialogResponseEntry children and anything
        // past the last slot is silently dropped (XUiC_DialogResponseList.Update), which is
        // invisible unless the two counts are compared.
        var rendered = new List<string>();
        if (windowGroup.responseWindow?.entryList != null)
        {
            foreach (XUiC_DialogResponseEntry entry in windowGroup.responseWindow.entryList)
            {
                if (entry?.CurrentResponse != null)
                {
                    rendered.Add(entry.CurrentResponse.ID);
                }
            }
        }

        var json = new StringBuilder();
        json.Append("{\"statement\":").Append(Quote(statement.ID));
        json.Append(",\"statement_text\":").Append(Quote(statement.Text));
        json.Append(",\"language\":").Append(Quote(ActiveLanguage));
        json.Append(",\"entries\":[");
        for (int i = 0; i < entries.Count; i++)
        {
            DialogResponse response = entries[i].Response;
            if (i > 0)
            {
                json.Append(',');
            }

            json.Append("{\"id\":").Append(Quote(response?.ID));
            json.Append(",\"text\":").Append(Quote(response?.Text)).Append('}');
        }

        json.Append("],\"rendered\":[");
        for (int i = 0; i < rendered.Count; i++)
        {
            if (i > 0)
            {
                json.Append(',');
            }

            json.Append(Quote(rendered[i]));
        }

        json.Append("]}");

        // Its own marker so a driver can pull the structured dump out of the console output
        // without it colliding with the TESTPILOT_RESULT line below.
        Output("TESTPILOT_DIALOG_DUMP " + json);
        EmitResult("dialog.dump", true, $"{entries.Count} entries, {rendered.Count} rendered");
    }

    private static void RunSelect(string responseId)
    {
        if (string.IsNullOrEmpty(responseId))
        {
            EmitResult("dialog.select", false, "a response id is required (see 'testpilot dialog dump')");
            return;
        }

        if (!TryGetWindowGroup(out XUiC_DialogWindowGroup windowGroup, out string error))
        {
            EmitResult("dialog.select", false, error);
            return;
        }

        Dialog dialog = windowGroup.CurrentDialog;
        DialogStatement statement = dialog?.CurrentStatement;
        if (statement == null)
        {
            EmitResult("dialog.select", false, "dialog has no current statement");
            return;
        }

        DialogResponse target = null;
        foreach (BaseResponseEntry entry in statement.GetResponses())
        {
            if (entry?.Response?.ID == responseId)
            {
                target = entry.Response;
                break;
            }
        }

        if (target == null)
        {
            EmitResult("dialog.select", false, $"no response '{responseId}' on statement '{statement.ID}'");
            return;
        }

        EntityPlayer player = GameManager.Instance?.World?.GetPrimaryPlayer();
        if (player == null)
        {
            EmitResult("dialog.select", false, "no primary player");
            return;
        }

        // Exactly what XUiC_DialogResponseList.OnPressResponse does for a real click.
        dialog.SelectResponse(target, player);
        windowGroup.RefreshDialog();
        EmitResult("dialog.select", true, responseId);
    }

    private static void RunClose()
    {
        LocalPlayerUI ui = LocalPlayerUI.GetUIForPrimaryPlayer();
        if (ui?.windowManager == null)
        {
            EmitResult("dialog.close", false, "no local player UI");
            return;
        }

        ui.windowManager.Close("dialog");
        EmitResult("dialog.close", true, "closed");
    }

    private static bool TryGetWindowGroup(out XUiC_DialogWindowGroup windowGroup, out string error)
    {
        windowGroup = null;
        LocalPlayerUI ui = LocalPlayerUI.GetUIForPrimaryPlayer();
        if (ui?.xui == null)
        {
            error = "no local player UI (dialog commands only run on a client)";
            return false;
        }

        windowGroup = ui.xui.Dialog?.DialogWindowGroup;
        if (windowGroup == null)
        {
            error = "no dialog is open (run 'testpilot dialog open <entityId>' first)";
            return false;
        }

        error = null;
        return true;
    }

    // 3.0 renamed this; the v2.6 line still calls it Localization.language.
    private static string ActiveLanguage =>
#if GAME_V26
        Localization.language;
#else
        Localization.ActiveLanguage;
#endif

    private static string Quote(string value)
    {
        if (value == null)
        {
            return "null";
        }

        var sb = new StringBuilder(value.Length + 2);
        sb.Append('"');
        foreach (char c in value)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (c < 0x20)
                    {
                        sb.Append("\\u").Append(((int)c).ToString("x4"));
                    }
                    else
                    {
                        sb.Append(c);
                    }

                    break;
            }
        }

        sb.Append('"');
        return sb.ToString();
    }

    private static void EmitResult(string action, bool ok, string detail)
    {
        Output($"TESTPILOT_RESULT {{\"action\":\"{action}\",\"ok\":{(ok ? "true" : "false")},\"detail\":{Quote(detail)}}}");
    }

    private static void Output(string message)
    {
        Log.Info(message);
        SdtdConsole.Instance.Output(message);
    }
}
#endif

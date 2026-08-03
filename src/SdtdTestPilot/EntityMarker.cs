#if TESTPILOT_ENABLED
using System.Collections.Generic;

namespace SdtdTestPilot;

// Writes the ownership markers the game itself uses, so a scenario can set up situations that
// cannot otherwise be reached without a human.
//
//   hired - the "Owner" Buffs custom var. SCore writes this when you hire an NPC, and
//           EntityUtilities.GetLeaderOrOwner reads it back, so a mod asking "is this a
//           companion" sees exactly what a real hire produces. Hiring for real goes through
//           NPC dialog, which a script cannot drive.
//   owned - belongsPlayerId, which a turret gets when a player places one. A console-spawned
//           turret comes out unowned, so without this the situation cannot be reproduced.
//
// This lives here rather than in the mod under test for the same reason `testpilot dialog`
// does: a harness compiled into a mod only exists in that mod's Debug build, so it can never
// set anything up against the Release build users download. Both markers are plain game state
// - a public field and a public Buffs call - so nothing here knows about any particular mod.
//
// It is test-only twice over: TESTPILOT_ENABLED is Debug-only, and TestPilotGate still has to
// find its marker file. Nothing in a shipped mod writes either value.
internal static class EntityMarker
{
    public static void Execute(List<string> args)
    {
        string marker = args.Count > 1 ? args[1].ToLowerInvariant() : string.Empty;
        string entityIdArg = args.Count > 2 ? args[2] : null;
        string playerIdArg = args.Count > 3 ? args[3] : null;

        if ((marker != "hired" && marker != "owned") || !int.TryParse(entityIdArg, out int entityId))
        {
            Output("[testpilot] usage: testpilot mark <hired|owned> <entityId> [playerEntityId]");
            return;
        }

        // Explicit when given, because these markers are read by whichever side owns the
        // world - a dedicated server, where there is no local player to resolve one from.
        int playerId;
        if (!string.IsNullOrEmpty(playerIdArg))
        {
            if (!int.TryParse(playerIdArg, out playerId))
            {
                Output("[testpilot] usage: testpilot mark <hired|owned> <entityId> [playerEntityId]");
                return;
            }
        }
        else
        {
            EntityPlayer player = GameManager.Instance?.World?.GetPrimaryPlayer();
            if (player == null)
            {
                EmitResult("mark", false, "no player context; pass the player entity id explicitly");
                return;
            }

            playerId = player.entityId;
        }

        if (!(GameManager.Instance?.World?.GetEntity(entityId) is EntityAlive alive))
        {
            EmitResult("mark", false, "no living entity with that id");
            return;
        }

        if (marker == "owned")
        {
            alive.belongsPlayerId = playerId;
            EmitResult("mark", true, $"{entityId} belongsPlayerId={playerId}");
            return;
        }

        if (alive.Buffs == null)
        {
            EmitResult("mark", false, "entity has no Buffs to write the Owner var to");
            return;
        }

        alive.Buffs.SetCustomVar("Owner", playerId);
        EmitResult("mark", true, $"{entityId} Owner={playerId}");
    }

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

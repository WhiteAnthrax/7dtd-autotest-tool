#if TESTPILOT_ENABLED
using System.Collections.Generic;

namespace SdtdTestPilot;

// Reads how many of an item a player is carrying, and puts items there to begin with.
//
// This is what makes the travel-cost path testable. The mod charges a configurable item per
// metre travelled, and the only untested part of that is the layer that actually removes the
// items from the player - a scenario cannot assert "exactly N were taken" without being able
// to count them before and after.
//
//   count <itemName> [playerEntityId]  - how many are in the toolbelt and the backpack
//   give  <itemName> <count> [playerEntityId] - puts items in, so the player can afford a trip
//
// Both use the same public API the game's own `giveself` command and every inventory screen
// use: EntityPlayer.inventory (the toolbelt) and EntityPlayer.bag (the backpack). Nothing
// here knows about any particular mod.
//
// The counts are reported separately as well as summed, because the mod's own inventory
// wrapper (GamePlayerInventory) reads both and a bug that only touches one of them would
// otherwise be invisible - the total would still be right.
internal static class InventoryReader
{
    public static void Execute(List<string> args)
    {
        string action = args.Count > 1 ? args[1].ToLowerInvariant() : string.Empty;
        switch (action)
        {
            case "count":
                RunCount(args.Count > 2 ? args[2] : null, args.Count > 3 ? args[3] : null);
                break;
            case "give":
                RunGive(args.Count > 2 ? args[2] : null,
                        args.Count > 3 ? args[3] : null,
                        args.Count > 4 ? args[4] : null);
                break;
            default:
                Output("[testpilot] usage: testpilot inventory <count <itemName> [playerEntityId]|" +
                       "give <itemName> <count> [playerEntityId]>");
                break;
        }
    }

    private static void RunCount(string itemName, string playerIdArg)
    {
        if (string.IsNullOrEmpty(itemName))
        {
            Output("[testpilot] usage: testpilot inventory count <itemName> [playerEntityId]");
            return;
        }

        if (!TryResolvePlayer(playerIdArg, out EntityPlayer player, out string failure))
        {
            EmitResult("inventory.count", false, failure);
            return;
        }

        if (!TryResolveItem(itemName, out ItemValue itemValue, out failure))
        {
            EmitResult("inventory.count", false, failure);
            return;
        }

        int toolbelt = player.inventory?.GetItemCount(itemValue) ?? 0;
        int backpack = player.bag?.GetItemCount(itemValue) ?? 0;
        Output($"TESTPILOT_INVENTORY {{\"item\":\"{Escape(itemName)}\",\"toolbelt\":{toolbelt}," +
               $"\"backpack\":{backpack},\"total\":{toolbelt + backpack}}}");
        EmitResult("inventory.count", true, $"{itemName}={toolbelt + backpack}");
    }

    private static void RunGive(string itemName, string countArg, string playerIdArg)
    {
        if (string.IsNullOrEmpty(itemName) || !int.TryParse(countArg, out int count) || count <= 0)
        {
            Output("[testpilot] usage: testpilot inventory give <itemName> <count> [playerEntityId]");
            return;
        }

        if (!TryResolvePlayer(playerIdArg, out EntityPlayer player, out string failure))
        {
            EmitResult("inventory.give", false, failure);
            return;
        }

        if (!TryResolveItem(itemName, out ItemValue itemValue, out failure))
        {
            EmitResult("inventory.give", false, failure);
            return;
        }

        // Into the backpack rather than the toolbelt: it has the room, and the mod reads both.
        if (player.bag == null)
        {
            EmitResult("inventory.give", false, "the player has no backpack to put items in");
            return;
        }

        var stack = new ItemStack(itemValue.Clone(), count);
        if (!player.bag.AddItem(stack))
        {
            EmitResult("inventory.give", false, $"could not fit {count} x {itemName} in the backpack");
            return;
        }

        int total = (player.inventory?.GetItemCount(itemValue) ?? 0) + player.bag.GetItemCount(itemValue);
        EmitResult("inventory.give", true, $"{itemName} now {total}");
    }

    // Explicit id when given, for the same reason `testpilot mark` takes one: on a dedicated
    // server there is no local player to resolve from.
    private static bool TryResolvePlayer(string playerIdArg, out EntityPlayer player, out string failure)
    {
        player = null;
        failure = null;

        if (!string.IsNullOrEmpty(playerIdArg))
        {
            if (!int.TryParse(playerIdArg, out int playerId))
            {
                failure = "the player entity id must be a number";
                return false;
            }

            player = GameManager.Instance?.World?.GetEntity(playerId) as EntityPlayer;
            if (player == null)
            {
                failure = "no player entity with that id";
                return false;
            }

            return true;
        }

        player = GameManager.Instance?.World?.GetPrimaryPlayer();
        if (player == null)
        {
            failure = "no player context; pass the player entity id explicitly";
            return false;
        }

        return true;
    }

    private static bool TryResolveItem(string itemName, out ItemValue itemValue, out string failure)
    {
        itemValue = null;
        failure = null;
        ItemClass itemClass = ItemClass.GetItemClass(itemName, true);
        if (itemClass == null)
        {
            failure = $"no such item: {itemName}";
            return false;
        }

        itemValue = new ItemValue(itemClass.Id, false);
        return true;
    }

    private static void EmitResult(string action, bool ok, string detail)
    {
        Output($"TESTPILOT_RESULT {{\"action\":\"{action}\",\"ok\":{(ok ? "true" : "false")},\"detail\":\"{Escape(detail)}\"}}");
    }

    private static string Escape(string value)
    {
        return (value ?? string.Empty).Replace("\\", "\\\\").Replace("\"", "\\\"");
    }

    private static void Output(string message)
    {
        Log.Info(message);
        SdtdConsole.Instance.Output(message);
    }
}
#endif

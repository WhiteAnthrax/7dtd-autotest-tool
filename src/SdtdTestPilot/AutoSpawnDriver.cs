#if TESTPILOT_ENABLED
namespace SdtdTestPilot;

// Does exactly what XUiC_SpawnSelectionWindow.SpawnButtonPressed(SpawnMethod.Invalid) does for
// a first-time spawn, without touching that window's UI at all: on a host/server, flip
// GameManager.canSpawnPlayer; on a remote client, ask the server via RequestToSpawn. Confirmed
// against 3.0.1 by decompiling XUiC_SpawnSelectionWindow - this is the same public API the
// "Spawn"/"Random Spawn" button calls, not a workaround.
//
// The readiness gate below mirrors XUiC_SpawnSelectionWindow.updateLoadState()'s own checks
// (game started, chunks displayed, distant terrain, UI ready) rather than a fixed delay.
// Requesting a spawn before the client is actually ready crashes EntityPlayerLocal.Init on the
// incoming NetPackagePlayerId (observed: NullReferenceException in SetFirstPersonView, from
// characterMatrixOverride not being set up yet) - a UI-ready check alone was not sufficient in
// testing against a remote dedicated server; the chunk/terrain checks were still needed.
internal static class AutoSpawnDriver
{
    private static bool _requested;

    public static void RequestSpawnIfNeeded()
    {
        if (_requested)
        {
            return;
        }
        if (GameManager.Instance == null || GameManager.Instance.World == null)
        {
            return;
        }
        if (GameManager.Instance.World.GetPrimaryPlayer() != null)
        {
            return;
        }
        if (!IsReadyForSpawnRequest())
        {
            return;
        }

        _requested = true;
        Log.Info("Requesting spawn for the primary player.");
        if (SingletonMonoBehaviour<ConnectionManager>.Instance.IsServer)
        {
            GameManager.Instance.canSpawnPlayer = true;
        }
        else
        {
            GameManager.Instance.RequestToSpawn();
        }
    }

    private static bool IsReadyForSpawnRequest()
    {
        if (!GameManager.Instance.gameStateManager.IsGameStarted())
        {
            return false;
        }

        World world = GameManager.Instance.World;
        int displayedChunkGameObjectsCount = world.m_ChunkManager.GetDisplayedChunkGameObjectsCount();
        int viewDistance = GameUtils.GetViewDistance();
        int requiredChunkObjects = world.ChunkCache.IsFixedSize ? 0 : (viewDistance * viewDistance - 10);
        if (displayedChunkGameObjectsCount < requiredChunkObjects)
        {
            return false;
        }

        if (DistantTerrain.Instance != null && !DistantTerrain.Instance.IsTerrainReady)
        {
            return false;
        }

        return IsClientUiReady();
    }

    private static bool IsClientUiReady()
    {
        LocalPlayerUI ui = LocalPlayerUI.GetUIForPrimaryPlayer();
#if GAME_V26
        // XUi's readiness flag is the lowercase field `isReady` on 7DTD v2.6 (confirmed by
        // decompiling XUiC_SpawnSelectionWindow.updateLoadState() against v2.6 b14); 3.0
        // renamed it to the PascalCase property `IsReady`.
        return ui != null && ui.xui != null && ui.xui.isReady;
#else
        return ui != null && ui.xui != null && ui.xui.IsReady;
#endif
    }
}
#endif

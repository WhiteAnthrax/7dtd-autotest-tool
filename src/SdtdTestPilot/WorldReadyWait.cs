#if TESTPILOT_ENABLED
using System.Collections;
using UnityEngine;

namespace SdtdTestPilot;

// HandleIpPortInvite's _onFinished only means the connect request was accepted, not that the
// world has actually loaded and the local player has spawned. StartServers is similarly
// fire-and-forget. Both driver paths route through here before the command queue opens, so an
// external driver never races a `vtttest`/console command against a still-loading world.
internal static class WorldReadyWait
{
    public static IEnumerator Wait(float timeoutSeconds, TestPilotOptions options)
    {
        float elapsed = 0f;
        float stepSeconds = 0.5f;
        while (GameManager.Instance == null
            || GameManager.Instance.World == null
            || GameManager.Instance.World.GetPrimaryPlayer() == null)
        {
            AutoSpawnDriver.RequestSpawnIfNeeded();
            if (elapsed >= timeoutSeconds)
            {
                Log.Error("World-ready wait timed out after " + timeoutSeconds + "s.");
                yield break;
            }

            yield return new WaitForSeconds(stepSeconds);
            elapsed += stepSeconds;
        }

        Log.Info("World is ready; starting command queue.");
        CommandQueuePoller.Start(options);
    }
}
#endif

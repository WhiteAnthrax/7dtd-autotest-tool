#if TESTPILOT_ENABLED
using UnityEngine;

namespace SdtdTestPilot;

internal static class Log
{
    public static void Info(string message)
    {
        Debug.Log("[SdtdTestPilot] " + message);
    }

    public static void Warn(string message)
    {
        Debug.LogWarning("[SdtdTestPilot] " + message);
    }

    public static void Error(string message)
    {
        Debug.LogError("[SdtdTestPilot] " + message);
    }
}
#endif

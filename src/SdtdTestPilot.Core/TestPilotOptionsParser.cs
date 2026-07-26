using System;
using System.Collections.Generic;

namespace SdtdTestPilot;

public static class TestPilotOptionsParser
{
    public const int DefaultPollIntervalMs = 250;
    public const int DefaultReadyTimeoutSeconds = 120;

    private const string Prefix = "-testpilot.";
    private const int MinPort = 1;
    private const int MaxPort = 65530;

    public static TestPilotOptions Parse(IEnumerable<string> commandLineArgs)
    {
        Dictionary<string, string> values = ExtractValues(commandLineArgs);

        int pollIntervalMs = GetInt(values, "pollms", DefaultPollIntervalMs);
        int readyTimeoutSeconds = GetInt(values, "readytimeout", DefaultReadyTimeoutSeconds);
        string queueDir = GetOrNull(values, "queue");

        if (string.IsNullOrEmpty(queueDir))
        {
            return TestPilotOptions.Disabled;
        }

        string modeText = GetOrNull(values, "mode");

        if (string.Equals(modeText, "connect", StringComparison.OrdinalIgnoreCase))
        {
            string ip = GetOrNull(values, "ip");
            int port = GetInt(values, "port", -1);
            if (string.IsNullOrEmpty(ip) || port < MinPort || port > MaxPort)
            {
                return TestPilotOptions.Disabled;
            }
            string password = GetOrNull(values, "password");
            return new TestPilotOptions(TestPilotMode.Connect, ip, port, password, null, null, queueDir, pollIntervalMs, readyTimeoutSeconds);
        }

        if (string.Equals(modeText, "hostload", StringComparison.OrdinalIgnoreCase))
        {
            string world = GetOrNull(values, "world");
            string gameName = GetOrNull(values, "gamename");
            if (string.IsNullOrEmpty(world) || string.IsNullOrEmpty(gameName))
            {
                return TestPilotOptions.Disabled;
            }
            return new TestPilotOptions(TestPilotMode.HostLoad, null, 0, null, world, gameName, queueDir, pollIntervalMs, readyTimeoutSeconds);
        }

        return TestPilotOptions.Disabled;
    }

    private static Dictionary<string, string> ExtractValues(IEnumerable<string> commandLineArgs)
    {
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (commandLineArgs == null)
        {
            return values;
        }

        foreach (string arg in commandLineArgs)
        {
            if (arg == null || !arg.StartsWith(Prefix, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            int equalsIndex = arg.IndexOf('=');
            if (equalsIndex <= Prefix.Length)
            {
                continue;
            }
            string key = arg.Substring(Prefix.Length, equalsIndex - Prefix.Length);
            string value = arg.Substring(equalsIndex + 1);
            values[key] = value;
        }

        return values;
    }

    private static string GetOrNull(Dictionary<string, string> values, string key)
    {
        return values.TryGetValue(key, out string value) && !string.IsNullOrEmpty(value) ? value : null;
    }

    private static int GetInt(Dictionary<string, string> values, string key, int defaultValue)
    {
        if (values.TryGetValue(key, out string value) && int.TryParse(value, out int parsed))
        {
            return parsed;
        }
        return defaultValue;
    }
}

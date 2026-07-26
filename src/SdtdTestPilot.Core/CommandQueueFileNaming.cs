using System;
using System.Collections.Generic;

namespace SdtdTestPilot;

public static class CommandQueueFileNaming
{
    private const string CommandExtension = ".cmd";
    private const string ResultExtension = ".result";

    public static IEnumerable<string> EnumerateReadyIds(IEnumerable<string> inDirFileNames)
    {
        var ids = new List<string>();
        if (inDirFileNames != null)
        {
            foreach (string fileName in inDirFileNames)
            {
                if (TryParseId(fileName, out string id))
                {
                    ids.Add(id);
                }
            }
        }
        ids.Sort(StringComparer.Ordinal);
        return ids;
    }

    public static bool TryParseId(string cmdFileName, out string id)
    {
        id = null;
        if (string.IsNullOrEmpty(cmdFileName) || !cmdFileName.EndsWith(CommandExtension, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }
        string candidate = cmdFileName.Substring(0, cmdFileName.Length - CommandExtension.Length);
        if (candidate.Length == 0)
        {
            return false;
        }
        id = candidate;
        return true;
    }

    public static string CommandFileName(string id)
    {
        return id + CommandExtension;
    }

    public static string ResultFileName(string id)
    {
        return id + ResultExtension;
    }
}

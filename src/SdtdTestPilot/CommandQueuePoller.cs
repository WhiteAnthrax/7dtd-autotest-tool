#if TESTPILOT_ENABLED
using System;
using System.Collections;
using System.IO;
using System.Linq;
using UnityEngine;

namespace SdtdTestPilot;

// Watches <queue>/in for *.cmd files dropped (atomically, via tmp+rename) by an external test
// driver, runs each through the local console, and writes the result back to <queue>/out. This
// is the mod's only external I/O surface, and it is local-filesystem-only: no socket is ever
// opened, so the queue directory's filesystem permissions are the whole security boundary.
internal static class CommandQueuePoller
{
    private static bool _started;

    public static void Start(TestPilotOptions options)
    {
        if (_started)
        {
            return;
        }

        _started = true;
        ThreadManager.StartCoroutine(PollLoop(options));
    }

    private static IEnumerator PollLoop(TestPilotOptions options)
    {
        string inDir = Path.Combine(options.QueueDir, "in");
        string outDir = Path.Combine(options.QueueDir, "out");
        string processedDir = Path.Combine(options.QueueDir, "processed");

        Directory.CreateDirectory(inDir);
        Directory.CreateDirectory(outDir);
        Directory.CreateDirectory(processedDir);
        AtomicFileWriter.WriteThenRename(options.QueueDir, "READY", DateTime.UtcNow.ToString("o"));
        Log.Info("Command queue ready at " + options.QueueDir);

        float waitSeconds = Math.Max(0.05f, options.PollIntervalMs / 1000f);
        while (true)
        {
            string[] cmdFiles = Directory.Exists(inDir)
                ? Directory.GetFiles(inDir, "*.cmd").OrderBy(f => f, StringComparer.Ordinal).ToArray()
                : Array.Empty<string>();

            foreach (string cmdFile in cmdFiles)
            {
                ProcessOne(cmdFile, outDir, processedDir);
            }

            yield return new WaitForSeconds(waitSeconds);
        }
    }

    private static void ProcessOne(string cmdFilePath, string outDir, string processedDir)
    {
        string fileName = Path.GetFileName(cmdFilePath);
        if (!CommandQueueFileNaming.TryParseId(fileName, out string id))
        {
            return;
        }

        string commandLine;
        try
        {
            commandLine = File.ReadAllText(cmdFilePath).Trim();
        }
        catch (IOException)
        {
            // Reader lost a race with a writer that has not finished the tmp+rename yet;
            // retry on the next poll tick instead of consuming a partially written file.
            return;
        }

        bool ok = ConsoleCommandRunner.TryExecute(commandLine, out string output);
        string json = CommandResultJson.Build(id, commandLine, ok, output, DateTime.UtcNow);
        AtomicFileWriter.WriteThenRename(outDir, CommandQueueFileNaming.ResultFileName(id), json);

        try
        {
            string destination = Path.Combine(processedDir, fileName);
            if (File.Exists(destination))
            {
                File.Delete(destination);
            }
            File.Move(cmdFilePath, destination);
        }
        catch (IOException ex)
        {
            Log.Warn("Could not move processed command file '" + fileName + "': " + ex.Message);
        }
    }
}
#endif

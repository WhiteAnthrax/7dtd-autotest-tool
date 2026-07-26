#if TESTPILOT_ENABLED
using System.IO;
using System.Text;

namespace SdtdTestPilot;

// Writes to a temp file then renames into place. A same-volume File.Move is atomic, so a
// reader watching `directory` never observes a partially written file under `finalFileName`.
internal static class AtomicFileWriter
{
    public static void WriteThenRename(string directory, string finalFileName, string content)
    {
        Directory.CreateDirectory(directory);
        string tmpPath = Path.Combine(directory, finalFileName + ".tmp");
        string finalPath = Path.Combine(directory, finalFileName);
        File.WriteAllText(tmpPath, content, new UTF8Encoding(false));
        if (File.Exists(finalPath))
        {
            File.Delete(finalPath);
        }
        File.Move(tmpPath, finalPath);
    }
}
#endif

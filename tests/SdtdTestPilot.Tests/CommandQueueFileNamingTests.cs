using System.Collections.Generic;
using System.Linq;
using SdtdTestPilot;
using Xunit;

namespace SdtdTestPilot.Tests;

public class CommandQueueFileNamingTests
{
    [Fact]
    public void TryParseId_CmdExtension_ReturnsIdWithoutExtension()
    {
        bool parsed = CommandQueueFileNaming.TryParseId("00000001.cmd", out string id);

        Assert.True(parsed);
        Assert.Equal("00000001", id);
    }

    [Fact]
    public void TryParseId_WrongExtension_ReturnsFalse()
    {
        bool parsed = CommandQueueFileNaming.TryParseId("00000001.txt", out string id);

        Assert.False(parsed);
        Assert.Null(id);
    }

    [Fact]
    public void TryParseId_EmptyIdBeforeExtension_ReturnsFalse()
    {
        bool parsed = CommandQueueFileNaming.TryParseId(".cmd", out string id);

        Assert.False(parsed);
    }

    [Fact]
    public void TryParseId_NullOrEmpty_ReturnsFalse()
    {
        Assert.False(CommandQueueFileNaming.TryParseId(null, out _));
        Assert.False(CommandQueueFileNaming.TryParseId(string.Empty, out _));
    }

    [Fact]
    public void EnumerateReadyIds_MixedFileNames_ReturnsOnlyCmdFilesSortedOrdinally()
    {
        var fileNames = new[] { "00000003.cmd", "00000001.cmd", "readme.txt", "00000002.cmd" };

        List<string> ids = CommandQueueFileNaming.EnumerateReadyIds(fileNames).ToList();

        Assert.Equal(new[] { "00000001", "00000002", "00000003" }, ids);
    }

    [Fact]
    public void EnumerateReadyIds_NoCmdFiles_ReturnsEmpty()
    {
        List<string> ids = CommandQueueFileNaming.EnumerateReadyIds(new[] { "readme.txt" }).ToList();

        Assert.Empty(ids);
    }

    [Fact]
    public void CommandFileName_AndResultFileName_RoundTripFromId()
    {
        Assert.Equal("00000042.cmd", CommandQueueFileNaming.CommandFileName("00000042"));
        Assert.Equal("00000042.result", CommandQueueFileNaming.ResultFileName("00000042"));
    }
}

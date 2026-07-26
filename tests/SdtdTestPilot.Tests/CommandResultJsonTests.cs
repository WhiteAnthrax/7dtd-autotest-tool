using System;
using SdtdTestPilot;
using Xunit;

namespace SdtdTestPilot.Tests;

public class CommandResultJsonTests
{
    [Fact]
    public void Build_SuccessfulCommand_ContainsAllFields()
    {
        var timestamp = new DateTime(2026, 7, 26, 3, 14, 0, DateTimeKind.Utc);

        string json = CommandResultJson.Build("00000001", "vtttest list", ok: true, output: "no records", utcTimestamp: timestamp);

        Assert.Equal(
            "{\"id\":\"00000001\",\"command\":\"vtttest list\",\"ok\":true,\"output\":\"no records\",\"timestamp\":\"2026-07-26T03:14:00.0000000Z\"}",
            json);
    }

    [Fact]
    public void Build_FailedCommand_OkIsFalse()
    {
        string json = CommandResultJson.Build("1", "badcmd", ok: false, output: "unknown command", utcTimestamp: DateTime.UtcNow);

        Assert.Contains("\"ok\":false", json);
    }

    [Fact]
    public void Build_NullOutput_SerializesAsJsonNull()
    {
        string json = CommandResultJson.Build("1", "cmd", ok: true, output: null, utcTimestamp: DateTime.UtcNow);

        Assert.Contains("\"output\":null", json);
    }

    [Fact]
    public void Build_OutputWithQuotesAndBackslashes_IsEscaped()
    {
        string json = CommandResultJson.Build("1", "cmd", ok: true, output: "he said \"hi\" \\ ok", utcTimestamp: DateTime.UtcNow);

        Assert.Contains("\"he said \\\"hi\\\" \\\\ ok\"", json);
    }

    [Fact]
    public void Build_OutputWithNewlines_IsEscaped()
    {
        string json = CommandResultJson.Build("1", "cmd", ok: true, output: "line1\nline2\r\n", utcTimestamp: DateTime.UtcNow);

        Assert.Contains("line1\\nline2\\r\\n", json);
        Assert.DoesNotContain("\n", json);
        Assert.DoesNotContain("\r", json);
    }
}

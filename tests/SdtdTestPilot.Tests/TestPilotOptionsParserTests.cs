using SdtdTestPilot;
using Xunit;

namespace SdtdTestPilot.Tests;

public class TestPilotOptionsParserTests
{
    [Fact]
    public void Parse_NoArguments_ReturnsDisabled()
    {
        TestPilotOptions options = TestPilotOptionsParser.Parse(new string[0]);

        Assert.Equal(TestPilotMode.None, options.Mode);
    }

    [Fact]
    public void Parse_QueueOnlyNoMode_ReturnsDisabled()
    {
        TestPilotOptions options = TestPilotOptionsParser.Parse(new[]
        {
            "-testpilot.queue=/tmp/queue",
        });

        Assert.Equal(TestPilotMode.None, options.Mode);
    }

    [Fact]
    public void Parse_ConnectModeWithIpPortQueue_ReturnsConnectOptions()
    {
        TestPilotOptions options = TestPilotOptionsParser.Parse(new[]
        {
            "-testpilot.mode=connect",
            "-testpilot.ip=192.168.1.50",
            "-testpilot.port=26900",
            "-testpilot.queue=/tmp/queue",
        });

        Assert.Equal(TestPilotMode.Connect, options.Mode);
        Assert.Equal("192.168.1.50", options.Ip);
        Assert.Equal(26900, options.Port);
        Assert.Equal("/tmp/queue", options.QueueDir);
        Assert.Null(options.Password);
        Assert.Equal(TestPilotOptionsParser.DefaultPollIntervalMs, options.PollIntervalMs);
        Assert.Equal(TestPilotOptionsParser.DefaultReadyTimeoutSeconds, options.ReadyTimeoutSeconds);
    }

    [Fact]
    public void Parse_ConnectModeWithPassword_CarriesPasswordThrough()
    {
        TestPilotOptions options = TestPilotOptionsParser.Parse(new[]
        {
            "-testpilot.mode=connect",
            "-testpilot.ip=192.168.1.50",
            "-testpilot.port=26900",
            "-testpilot.password=hunter2",
            "-testpilot.queue=/tmp/queue",
        });

        Assert.Equal("hunter2", options.Password);
    }

    [Fact]
    public void Parse_ConnectModeMissingIp_ReturnsDisabled()
    {
        TestPilotOptions options = TestPilotOptionsParser.Parse(new[]
        {
            "-testpilot.mode=connect",
            "-testpilot.port=26900",
            "-testpilot.queue=/tmp/queue",
        });

        Assert.Equal(TestPilotMode.None, options.Mode);
    }

    [Theory]
    [InlineData("0")]
    [InlineData("65531")]
    [InlineData("notanumber")]
    public void Parse_ConnectModePortOutOfRange_ReturnsDisabled(string port)
    {
        TestPilotOptions options = TestPilotOptionsParser.Parse(new[]
        {
            "-testpilot.mode=connect",
            "-testpilot.ip=192.168.1.50",
            "-testpilot.port=" + port,
            "-testpilot.queue=/tmp/queue",
        });

        Assert.Equal(TestPilotMode.None, options.Mode);
    }

    [Fact]
    public void Parse_HostLoadModeWithWorldAndGameName_ReturnsHostLoadOptions()
    {
        TestPilotOptions options = TestPilotOptionsParser.Parse(new[]
        {
            "-testpilot.mode=hostload",
            "-testpilot.world=Navezgane",
            "-testpilot.gamename=TestPilotLocal",
            "-testpilot.queue=/tmp/queue",
        });

        Assert.Equal(TestPilotMode.HostLoad, options.Mode);
        Assert.Equal("Navezgane", options.World);
        Assert.Equal("TestPilotLocal", options.GameName);
    }

    [Fact]
    public void Parse_HostLoadModeMissingGameName_ReturnsDisabled()
    {
        TestPilotOptions options = TestPilotOptionsParser.Parse(new[]
        {
            "-testpilot.mode=hostload",
            "-testpilot.world=Navezgane",
            "-testpilot.queue=/tmp/queue",
        });

        Assert.Equal(TestPilotMode.None, options.Mode);
    }

    [Fact]
    public void Parse_UnknownMode_ReturnsDisabled()
    {
        TestPilotOptions options = TestPilotOptionsParser.Parse(new[]
        {
            "-testpilot.mode=teleport",
            "-testpilot.queue=/tmp/queue",
        });

        Assert.Equal(TestPilotMode.None, options.Mode);
    }

    [Fact]
    public void Parse_ModeIsCaseInsensitive()
    {
        TestPilotOptions options = TestPilotOptionsParser.Parse(new[]
        {
            "-testpilot.mode=CONNECT",
            "-testpilot.ip=192.168.1.50",
            "-testpilot.port=26900",
            "-testpilot.queue=/tmp/queue",
        });

        Assert.Equal(TestPilotMode.Connect, options.Mode);
    }

    [Fact]
    public void Parse_CustomPollAndTimeout_OverridesDefaults()
    {
        TestPilotOptions options = TestPilotOptionsParser.Parse(new[]
        {
            "-testpilot.mode=connect",
            "-testpilot.ip=192.168.1.50",
            "-testpilot.port=26900",
            "-testpilot.queue=/tmp/queue",
            "-testpilot.pollms=500",
            "-testpilot.readytimeout=60",
        });

        Assert.Equal(500, options.PollIntervalMs);
        Assert.Equal(60, options.ReadyTimeoutSeconds);
    }

    [Fact]
    public void Parse_UnrelatedArguments_AreIgnored()
    {
        TestPilotOptions options = TestPilotOptionsParser.Parse(new[]
        {
            "7DaysToDie.exe",
            "-nographics",
            "-batchmode",
            "-testpilot.mode=connect",
            "-testpilot.ip=192.168.1.50",
            "-testpilot.port=26900",
            "-testpilot.queue=/tmp/queue",
        });

        Assert.Equal(TestPilotMode.Connect, options.Mode);
    }
}

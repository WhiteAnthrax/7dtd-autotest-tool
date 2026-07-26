namespace SdtdTestPilot;

public sealed class TestPilotOptions
{
    public static readonly TestPilotOptions Disabled = new TestPilotOptions(
        TestPilotMode.None, null, 0, null, null, null, null, TestPilotOptionsParser.DefaultPollIntervalMs, TestPilotOptionsParser.DefaultReadyTimeoutSeconds);

    public TestPilotMode Mode { get; }
    public string Ip { get; }
    public int Port { get; }
    public string Password { get; }
    public string World { get; }
    public string GameName { get; }
    public string QueueDir { get; }
    public int PollIntervalMs { get; }
    public int ReadyTimeoutSeconds { get; }

    public TestPilotOptions(
        TestPilotMode mode,
        string ip,
        int port,
        string password,
        string world,
        string gameName,
        string queueDir,
        int pollIntervalMs,
        int readyTimeoutSeconds)
    {
        Mode = mode;
        Ip = ip;
        Port = port;
        Password = password;
        World = world;
        GameName = gameName;
        QueueDir = queueDir;
        PollIntervalMs = pollIntervalMs;
        ReadyTimeoutSeconds = readyTimeoutSeconds;
    }
}

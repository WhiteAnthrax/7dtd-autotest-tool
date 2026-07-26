#if TESTPILOT_ENABLED
namespace SdtdTestPilot;

internal static class TestPilotState
{
    public static TestPilotOptions Options { get; set; } = TestPilotOptions.Disabled;
}
#endif

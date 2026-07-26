using System;
using System.Globalization;
using System.Text;

namespace SdtdTestPilot;

public static class CommandResultJson
{
    public static string Build(string id, string command, bool ok, string output, DateTime utcTimestamp)
    {
        var sb = new StringBuilder();
        sb.Append('{');
        AppendField(sb, "id", id, first: true);
        AppendField(sb, "command", command, first: false);
        sb.Append(",\"ok\":").Append(ok ? "true" : "false");
        AppendField(sb, "output", output, first: false);
        AppendField(sb, "timestamp", utcTimestamp.ToString("o", CultureInfo.InvariantCulture), first: false);
        sb.Append('}');
        return sb.ToString();
    }

    private static void AppendField(StringBuilder sb, string name, string value, bool first)
    {
        if (!first)
        {
            sb.Append(',');
        }
        sb.Append('"').Append(name).Append("\":");
        AppendJsonString(sb, value);
    }

    private static void AppendJsonString(StringBuilder sb, string value)
    {
        if (value == null)
        {
            sb.Append("null");
            return;
        }

        sb.Append('"');
        foreach (char c in value)
        {
            switch (c)
            {
                case '"':
                    sb.Append("\\\"");
                    break;
                case '\\':
                    sb.Append("\\\\");
                    break;
                case '\n':
                    sb.Append("\\n");
                    break;
                case '\r':
                    sb.Append("\\r");
                    break;
                case '\t':
                    sb.Append("\\t");
                    break;
                default:
                    if (c < 0x20)
                    {
                        sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    }
                    else
                    {
                        sb.Append(c);
                    }
                    break;
            }
        }
        sb.Append('"');
    }
}

using System.Runtime.InteropServices;
using System.Text;

namespace DayLog.Win;

/// <summary>Win32 calls for the foreground window and its process. These are
/// rock-solid; UI Automation is used only for window content.</summary>
internal static class Native
{
    [DllImport("user32.dll")] internal static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    internal static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    internal static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    internal static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

    internal static string WindowTitle(IntPtr hWnd)
    {
        int len = GetWindowTextLength(hWnd);
        if (len <= 0) return "";
        var sb = new StringBuilder(len + 1);
        GetWindowText(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }
}

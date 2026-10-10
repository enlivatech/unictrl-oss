namespace Unictrl;

/// A Start menu entry, so Unictrl can be opened (its window shown) even with the notification-area
/// and taskbar icons turned off. A second launch asks the running copy to show its window.
internal static class StartMenuShortcut
{
    public static void Ensure()
    {
        try
        {
            var target = Environment.ProcessPath;
            if (target is null) return;
            var link = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "Unictrl.lnk");
            var shellType = Type.GetTypeFromProgID("WScript.Shell");
            if (shellType is null) return;
            dynamic shell = Activator.CreateInstance(shellType)!;
            if (File.Exists(link) && string.Equals((string)shell.CreateShortcut(link).TargetPath, target, StringComparison.OrdinalIgnoreCase))
                return;
            dynamic shortcut = shell.CreateShortcut(link);
            shortcut.TargetPath = target;
            shortcut.WorkingDirectory = Path.GetDirectoryName(target);
            shortcut.Description = "Unictrl";
            shortcut.Save();
            Log.Write("start_menu_shortcut", "created");
        }
        catch (Exception ex)
        {
            Log.Write("start_menu_shortcut_failed", ex.GetType().Name);
        }
    }
}

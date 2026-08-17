' Launches the tray app with no console window. Drop a shortcut to this in shell:startup.
Set s = CreateObject("WScript.Shell")
s.CurrentDirectory = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
s.Run "powershell -NoProfile -ExecutionPolicy Bypass -File ""monitor-sleeper.ps1""", 0, False

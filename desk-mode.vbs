' Desktop mode, no window. Make a shortcut to this file for an icon or hotkey.
Set sh = CreateObject("WScript.Shell")
dir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
sh.Run "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & dir & "switch-mode.ps1"" -Mode desk", 0, False

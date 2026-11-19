Option Explicit
Dim fso, sh, parentFolder, path, command
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
parentFolder = fso.GetParentFolderName(WScript.ScriptFullName)
path = fso.BuildPath(parentFolder, "DGGS_Control_Center.ps1")
command = "powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & path & Chr(34)
sh.Run command, 0, False

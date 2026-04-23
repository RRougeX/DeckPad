Set shell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
arguments = ""
If WScript.Arguments.Count > 0 Then
    For Each arg In WScript.Arguments
        arguments = arguments & " " & arg
    Next
End If
command = "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptDir & "\DeckPad.ps1""" & arguments
shell.Run command, 0, False

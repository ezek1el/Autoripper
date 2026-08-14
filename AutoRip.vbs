' ---------------------------------------------------------------------
'  AutoRip.vbs - flackerfreier Starter fuer ezek1el3000's AutoRip
'  Author: ezek1el3000
'
'  Startet AutoRipGUI.ps1 ohne kurz aufblitzendes Konsolenfenster.
'  Das Script wird im selben Ordner wie diese VBS-Datei erwartet.
' ---------------------------------------------------------------------

Dim fso, shell, scriptDir, target, cmd

Set fso   = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("Wscript.Shell")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
target    = fso.BuildPath(scriptDir, "AutoRipGUI.ps1")

If Not fso.FileExists(target) Then
    MsgBox "AutoRipGUI.ps1 wurde nicht gefunden:" & vbCrLf & target, _
           vbCritical, "AutoRip"
    WScript.Quit 1
End If

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & target & """"

' 0 = Fenster unsichtbar, False = nicht auf Beendigung warten
shell.Run cmd, 0, False

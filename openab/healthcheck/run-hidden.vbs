' run-hidden.vbs - launch a PowerShell script with no visible console window.
'
' Why this exists:
'   Registering the scheduled task to run powershell.exe directly pops a console
'   window every 5 minutes, which interrupts whoever is using the machine.
'   -WindowStyle Hidden is not enough: the console host is created before
'   PowerShell applies the style, so it still flashes.
'
'   WScript.Shell.Run with intWindowStyle=0 never creates a visible window.
'   bWaitOnReturn=True makes Run return the child's exit code, which is then
'   passed through with WScript.Quit -- that keeps Task Scheduler's
'   LastTaskResult meaningful. LastTaskResult=0 is the watchdog's own health
'   signal, so losing it would defeat the purpose of the task.
'
' Usage:
'   wscript.exe //nologo run-hidden.vbs "<full path to .ps1>"

Option Explicit

Dim shell, cmd, rc

If WScript.Arguments.Count < 1 Then
  WScript.Quit 2
End If

Set shell = CreateObject("WScript.Shell")

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & WScript.Arguments(0) & """"

rc = shell.Run(cmd, 0, True)

WScript.Quit rc

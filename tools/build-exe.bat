@echo off
rem Rebuilds MonitorControl.exe (a small launcher for tray.ps1) using the C# compiler that ships with Windows.
cd /d "%~dp0.."
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
"%CSC%" /nologo /target:winexe /platform:anycpu /out:MonitorControl.exe /win32icon:tools\monitor-control.ico tools\launcher.cs
if errorlevel 1 (echo Build failed) else (echo Built MonitorControl.exe)
pause

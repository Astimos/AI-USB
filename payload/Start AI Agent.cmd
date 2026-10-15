@echo off
rem AI USB - Windows launcher. Double-click to start the AI agents.
title AISTiUSB
rem Show Windows users only this file and README.txt: hide the Linux launcher,
rem the Linux hide-list, the internals folder and the Windows installer files
rem (the stick keeps the attribute).
attrib +h "%~dp0start-ai-agent.sh" >nul 2>nul
attrib +h "%~dp0.hidden" >nul 2>nul
attrib +h "%~dp0aiusb" >nul 2>nul
if exist "%~dp0sources\install.*" attrib +h "%~dp0sources" >nul 2>nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0aiusb\launcher\launcher.ps1"
if errorlevel 1 pause

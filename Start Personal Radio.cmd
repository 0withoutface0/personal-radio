@echo off
"%~dp0.venv\Scripts\python.exe" "%~dp0scripts\launch_player.py"
if errorlevel 1 pause

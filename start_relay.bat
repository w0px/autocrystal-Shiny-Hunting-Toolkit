@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "discord_relay.ps1"
pause

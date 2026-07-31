@echo off
cd /d "%~dp0"
rem Manual fallback only - launcher.lua auto-launches this relay for you
rem now, so you shouldn't normally need to run this yourself. Kept here
rem in case auto-launch ever fails (e.g. PowerShell blocked) and you
rem need to start it by hand, or for testing.
rem
rem All defaults (ClientId, ButtonUrl, etc) already point at autocrystal's
rem real application/repo - no arguments needed.
powershell -NoProfile -ExecutionPolicy Bypass -File "discord_presence_relay.ps1"
pause

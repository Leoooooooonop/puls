@echo off
rem Startet PULS lokal (fragt nach Adminrechten).
powershell -NoProfile -ExecutionPolicy Bypass -STA -Command "$env:PULS_PFAD='%~dp0puls.ps1'; iex ([IO.File]::ReadAllText($env:PULS_PFAD, [Text.Encoding]::UTF8))"

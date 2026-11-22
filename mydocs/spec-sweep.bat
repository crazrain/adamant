@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0spec-sweep.ps1" %*

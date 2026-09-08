@echo off
setlocal

REM Higgs Audio v3 Server Launcher (Windows)
REM Starts the audio.cpp server with config from the kit directory

net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

setlocal enabledelayedexpansion

REM Paths relative to this batch file
for %%I in ("%~dp0..") do set "ROOT=%%~fI"
set "SERVER=%ROOT%\runtime\audiocpp_server.exe"
set "CONFIG=%ROOT%\config\server.json"
set "MODEL=%ROOT%\models\higgs-audio-v3-tts-4b-q8_0.gguf"
set "LOGS=%ROOT%\logs"

if not exist "%SERVER%" (
  echo [ERROR] audiocpp_server.exe not found at %SERVER%
  echo Please download audio.cpp from: https://github.com/kigner/audio.cpp-webui/releases
  pause
  exit /b 1
)

if not exist "%MODEL%" (
  echo [ERROR] Model not found at %MODEL%
  echo Please run scripts\download-model.sh or download manually.
  pause
  exit /b 1
)

if not exist "%CONFIG%" (
  echo [ERROR] Config not found at %CONFIG%
  echo Copy config\server.example.json to config\server.json first.
  pause
  exit /b 1
)

if not exist "%LOGS%" mkdir "%LOGS%"

echo Starting Higgs Audio v3 server...
echo Server: %SERVER%
echo Config: %CONFIG%
echo.

start "Higgs Audio v3 Server" "%SERVER%" --config "%CONFIG%" --backend cpu

echo Server started in background.
echo API endpoint: http://127.0.0.1:8188
echo Close this window to stop the server.
pause

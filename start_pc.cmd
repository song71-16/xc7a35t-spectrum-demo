@echo off
setlocal
cd /d "%~dp0"
if defined DEMO_PYTHON goto configured
if exist ".venv\Scripts\python.exe" (
  ".venv\Scripts\python.exe" tools\launch_pc.py %*
  exit /b
)
python tools\launch_pc.py %*
exit /b
:configured
"%DEMO_PYTHON%" tools\launch_pc.py %*
exit /b

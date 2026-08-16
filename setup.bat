@echo off
:: Windows 1-Click Launcher for WSL2 LLM Platform
echo ============================================================
echo  Launching Local LLM Platform Setup in WSL2...
echo ============================================================

wsl -d Ubuntu bash -ic "cd ~/llm-platform-iac && ./setup.sh"

echo.
echo Setup finished. Press any key to close...
pause > nul

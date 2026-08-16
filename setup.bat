@echo off
:: Windows 1-Click Launcher for WSL2 LLM Platform
echo ============================================================
echo  Zero-Trust Local LLM Platform — WSL2 Launcher
echo ============================================================

:: Check if WSL is installed
wsl --version >nul 2>&1
if %errorlevel% neq 0 (
    echo [!] WSL2 is not installed. Run first:
    echo     wsl --install -d Ubuntu
    echo     ^(Then restart your PC and re-run this script^)
    pause
    exit /b 1
)

:: Check if Ubuntu is installed
wsl -l -v | findstr "Ubuntu" >nul 2>&1
if %errorlevel% neq 0 (
    echo [!] Ubuntu is not installed in WSL. Run:
    echo     wsl --install -d Ubuntu
    pause
    exit /b 1
)

:: Find the repo inside WSL (handles any clone directory name)
echo [*] Locating repository in WSL2...
for /f "tokens=*" %%a in ('wsl -d Ubuntu bash -ic "find ~ -maxdepth 2 -name setup.sh -path */scripts/setup.sh 2>/dev/null | head -n 1 | xargs dirname | xargs dirname"') do set REPO_PATH=%%a

if "%REPO_PATH%"=="" (
    echo [!] Could not find the repository in WSL2.
    echo     Make sure you cloned it: git clone https://github.com/k0r4y/zero-trust-llm-gateway.git
    pause
    exit /b 1
)

echo [✔] Found repository at: %REPO_PATH%

:: Run the setup wizard inside WSL2
echo [*] Launching interactive setup wizard...
wsl -d Ubuntu bash -ic "cd %REPO_PATH% && ./setup.sh"

echo.
echo ============================================================
echo  Setup complete. Press any key to close...
echo ============================================================
pause > nul

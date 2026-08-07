@echo off
setlocal EnableDelayedExpansion

:: ============================================================
::  Mr. Benkhriza SteamTools Setup v3.1
::  Automatically installs dependencies and Steam tools.
::  Made by Benkhriza.
:: ============================================================

title Mr. Benkhriza SteamTools - Setup v3.1
cd /d "%~dp0"

:: ---------------------------------------------------------------------------
:: Step 0 - Auto-elevate to Administrator
:: ---------------------------------------------------------------------------
net session >nul 2>&1
if %errorlevel% neq 0 (
    cls
    echo.
    echo  =====================================================
    echo    Mr. Benkhriza SteamTools v3.1 - Setup
    echo  =====================================================
    echo.
    echo  [INFO] Requesting Administrator privileges...
    echo  [INFO] Please click YES on the UAC prompt.
    echo.
    powershell -NoProfile -Command "Start-Process -FilePath cmd.exe -ArgumentList '/k \"\"%~f0\"\"' -Verb RunAs"
    exit /b 0
)

cd /d "%~dp0"

:: Repair mode flag
set "REPAIR_MODE=0"
if /I "%~1"=="repair"   set "REPAIR_MODE=1"
if /I "%~1"=="/repair"  set "REPAIR_MODE=1"
if /I "%~1"=="--repair" set "REPAIR_MODE=1"

set "SCRIPT_DIR=%~dp0"
if "!SCRIPT_DIR:~-1!"=="\" set "SCRIPT_DIR=!SCRIPT_DIR:~0,-1!"

set "DLL_SRC_DIR=!SCRIPT_DIR!"
if exist "!SCRIPT_DIR!\SteamFiles\OpenSteamTool.dll" set "DLL_SRC_DIR=!SCRIPT_DIR!\SteamFiles"

cls
echo.
echo  =====================================================
echo    Mr. Benkhriza SteamTools v3.1 - Automatic Setup
echo    Made by Benkhriza
echo  =====================================================
echo.
echo  Checking system dependencies...
echo  =====================================================
echo.

:: ---------------------------------------------------------------------------
:: Step 1 - Check PowerShell version
:: ---------------------------------------------------------------------------
for /f "usebackq delims=" %%V in (`powershell -NoProfile -Command "$PSVersionTable.PSVersion.Major" 2^>nul`) do set "PS_MAJOR=%%V"
if not defined PS_MAJOR set "PS_MAJOR=0"
if !PS_MAJOR! LSS 5 (
    echo  [WARN] PowerShell 5.1 or higher is recommended. You have v!PS_MAJOR!.
    echo  [INFO] Download PowerShell: https://aka.ms/wmf5download
    echo.
) else (
    echo  [OK] PowerShell v!PS_MAJOR! detected.
)

:: ---------------------------------------------------------------------------
:: Step 2 - Check & Install Microsoft Visual C++ Redistributable
:: ---------------------------------------------------------------------------
reg query "HKLM\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64" /v Version >nul 2>&1
if %errorlevel% neq 0 (
    reg query "HKLM\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x86" /v Version >nul 2>&1
)
if %errorlevel% neq 0 (
    echo  [INFO] Microsoft Visual C++ Runtime not found. Downloading...
    set "VCREDIST_URL=https://aka.ms/vs/17/release/vc_redist.x64.exe"
    set "VCREDIST_PATH=%TEMP%\vc_redist.x64.exe"
    powershell -NoProfile -Command "try { (New-Object Net.WebClient).DownloadFile('!VCREDIST_URL!', '!VCREDIST_PATH!'); Write-Host 'Downloaded.' } catch { Write-Host 'Download failed.' }"
    if exist "!VCREDIST_PATH!" (
        echo  [INFO] Installing Visual C++ Runtime silently...
        start /wait "!VCREDIST_PATH!" /install /quiet /norestart
        echo  [OK] Visual C++ Runtime installed.
        del /Q "!VCREDIST_PATH!" >nul 2>&1
    ) else (
        echo  [WARN] Could not download Visual C++ Runtime. Some features may not work.
        echo  [INFO] Download manually: https://aka.ms/vs/17/release/vc_redist.x64.exe
    )
) else (
    echo  [OK] Visual C++ Runtime detected.
)

:: ---------------------------------------------------------------------------
:: Step 3 - Check & Install Microsoft Edge WebView2 Runtime
::           (required for the Fetch LUA browser feature)
:: ---------------------------------------------------------------------------
set "WV2_FOUND=0"
reg query "HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" >nul 2>&1
if %errorlevel% equ 0 set "WV2_FOUND=1"
if !WV2_FOUND! equ 0 (
    reg query "HKCU\Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" >nul 2>&1
    if %errorlevel% equ 0 set "WV2_FOUND=1"
)

if !WV2_FOUND! equ 0 (
    echo  [INFO] Microsoft Edge WebView2 Runtime not found.
    echo  [INFO] This is needed for the automatic LUA Fetch feature.
    echo  [INFO] Downloading WebView2 installer...
    set "WV2_URL=https://go.microsoft.com/fwlink/p/?LinkId=2124703"
    set "WV2_PATH=%TEMP%\MicrosoftEdgeWebview2Setup.exe"
    powershell -NoProfile -Command "try { (New-Object Net.WebClient).DownloadFile('!WV2_URL!', '!WV2_PATH!'); Write-Host 'Downloaded.' } catch { Write-Host 'Download failed: ' + $_.Exception.Message }"
    if exist "!WV2_PATH!" (
        echo  [INFO] Installing WebView2 silently... (this may take a minute)
        start /wait "!WV2_PATH!" /silent /install
        echo  [OK] WebView2 Runtime installed.
        del /Q "!WV2_PATH!" >nul 2>&1
    ) else (
        echo  [WARN] Could not download WebView2 automatically.
        echo  [INFO] The app will still work, but automatic LUA fetching needs manual install.
        echo  [INFO] Download manually: https://developer.microsoft.com/microsoft-edge/webview2/
    )
) else (
    echo  [OK] Microsoft Edge WebView2 Runtime detected.
)

:: ---------------------------------------------------------------------------
:: Step 3b - Unblock downloaded files (Mark of the Web)
:: ---------------------------------------------------------------------------
echo  [INFO] Unblocking downloaded application files...
powershell -NoProfile -Command "Get-ChildItem -Path '!SCRIPT_DIR!' -Recurse | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1
echo  [OK] Files unblocked.
echo.

:: ---------------------------------------------------------------------------
:: Step 4 - Find Steam
:: ---------------------------------------------------------------------------
set "STEAM_PATH="
for /f "usebackq tokens=2,*" %%A in (`reg query "HKCU\Software\Valve\Steam" /v "SteamPath" 2^>nul`) do set "STEAM_PATH=%%B"
if defined STEAM_PATH set "STEAM_PATH=!STEAM_PATH:/=\!"

if not defined STEAM_PATH if exist "C:\Program Files (x86)\Steam\steam.exe" set "STEAM_PATH=C:\Program Files (x86)\Steam"
if not defined STEAM_PATH if exist "C:\Program Files\Steam\steam.exe"       set "STEAM_PATH=C:\Program Files\Steam"

if not defined STEAM_PATH (
    echo  [WARN] Steam not found automatically.
    echo.
    set /p "STEAM_PATH=  Enter your Steam path (e.g. C:\Program Files (x86)\Steam): "
    if not defined STEAM_PATH goto :fail_no_steam
)
set "STEAM_PATH=!STEAM_PATH:/=\!"
if not exist "!STEAM_PATH!\steam.exe" (
    echo  [WARN] steam.exe not found at: !STEAM_PATH!
    set /p "STEAM_PATH=  Enter correct Steam path: "
    if not exist "!STEAM_PATH!\steam.exe" goto :fail_no_steam
)
echo  [OK] Steam found at: !STEAM_PATH!
echo.

:: Check DLLs are present
if not exist "!DLL_SRC_DIR!\OpenSteamTool.dll" (
    echo  [ERROR] OpenSteamTool.dll NOT FOUND in: !DLL_SRC_DIR!
    echo  Make sure you extracted the full ZIP before running Setup.
    echo.
    pause >nul
    exit /b 1
)
echo  [OK] DLLs found in: !DLL_SRC_DIR!
echo.

:: ---------------------------------------------------------------------------
:: Step 5 - Close Steam
:: ---------------------------------------------------------------------------
tasklist /FI "IMAGENAME eq steam.exe" 2>nul | find /I "steam.exe" >nul
if not errorlevel 1 (
    echo  [INFO] Closing Steam for installation...
    taskkill /IM steam.exe /F >nul 2>&1
    timeout /t 3 /nobreak >nul
    echo  [OK] Steam closed.
)

:: ---------------------------------------------------------------------------
:: Step 6 - Install DLLs
:: ---------------------------------------------------------------------------
echo  [INFO] Copying DLL files...
set "DLL_OK=0"
set "DLL_FAIL=0"
for %%F in (dwmapi.dll xinput1_4.dll OpenSteamTool.dll) do (
    copy /Y "!DLL_SRC_DIR!\%%F" "!STEAM_PATH!\%%F" >nul 2>&1
    if !errorlevel! EQU 0 (
        echo   [OK] %%F
        set /a DLL_OK+=1
    ) else (
        echo   [ERROR] %%F  ^(check antivirus is not blocking^)
        set /a DLL_FAIL+=1
    )
)
echo.

:: ---------------------------------------------------------------------------
:: Step 7 - Create Lua dir and configs
:: ---------------------------------------------------------------------------
set "LUA_DIR=!STEAM_PATH!\config\lua"
if not exist "!LUA_DIR!" (
    mkdir "!LUA_DIR!" >nul 2>&1
    echo  [OK] Created: !LUA_DIR!
) else (
    echo  [OK] Lua directory ready.
)

:: Install manifest.lua
set "MANIFEST_SRC=!DLL_SRC_DIR!\manifest.lua"
if not exist "!MANIFEST_SRC!" set "MANIFEST_SRC=!SCRIPT_DIR!\manifest.lua"
if not exist "!MANIFEST_SRC!" if exist "!SCRIPT_DIR!\SteamFiles\config\lua\manifest.lua" set "MANIFEST_SRC=!SCRIPT_DIR!\SteamFiles\config\lua\manifest.lua"
if exist "!MANIFEST_SRC!" (
    copy /Y "!MANIFEST_SRC!" "!LUA_DIR!\manifest.lua" >nul 2>&1
    echo  [OK] manifest.lua installed.
) else (
    (
        echo -- manifest.lua -- Auto-generated
        echo function fetch_manifest_code(gid)
        echo     local body, st = http_get("https://manifest.steam.run/api/manifest/" .. gid)
        echo     if st == 200 and body then
        echo         local code = body:match('"content":"(%%d+)"')
        echo         if code then return code end
        echo     end
        echo     return nil
        echo end
    ) > "!LUA_DIR!\manifest.lua"
    echo  [OK] Created default manifest.lua
)

if not exist "!LUA_DIR!\mygames.lua" (
    (
        echo -- mygames.lua -- Add your game AppIDs here
        echo -- Example: addappid(1245620)  -- Elden Ring
    ) > "!LUA_DIR!\mygames.lua"
    echo  [OK] Created starter mygames.lua
) else (
    echo  [OK] mygames.lua already exists.
)
echo.

:: ---------------------------------------------------------------------------
:: Step 8 - Create Desktop shortcut
:: ---------------------------------------------------------------------------
set "DESKTOP=%USERPROFILE%\Desktop"
set "SHORTCUT_PATH=!DESKTOP!\Mr. Benkhriza.lnk"
set "TARGET_SCRIPT=!SCRIPT_DIR!\Mr. Benkhriza.ps1"
set "ICON_PATH=!SCRIPT_DIR!\Mr_Benkhriza_Logo.png"

:: Clean up old loose files
for %%F in ("Mr. Benkhriza.ps1" "Mr. Benkhriza.xaml" "Mr. Benkhriza.bat" "Mr_Benkhriza_Logo.png" "mr_benkhriza_gui.json") do (
    if exist "!DESKTOP!\%%~F" del /Q "!DESKTOP!\%%~F" >nul 2>&1
)
if exist "!DESKTOP!\database" rmdir /S /Q "!DESKTOP!\database" >nul 2>&1

powershell -NoProfile -Command "$ws = New-Object -ComObject WScript.Shell; $s = $ws.CreateShortcut('!SHORTCUT_PATH!'); $s.TargetPath = 'powershell.exe'; $s.Arguments = '-WindowStyle Hidden -STA -NoProfile -ExecutionPolicy Bypass -File \"\"'!TARGET_SCRIPT!'\"\"'; $s.WorkingDirectory = '!SCRIPT_DIR!'; if (Test-Path '!ICON_PATH!') { $s.IconLocation = '!ICON_PATH!' }; $s.Save()" >nul 2>&1

if exist "!SHORTCUT_PATH!" (
    echo  [OK] Desktop shortcut created: Mr. Benkhriza
) else (
    echo  [WARN] Creating fallback launcher on Desktop...
    (
        echo @echo off
        echo cd /d "!SCRIPT_DIR!"
        echo start "" powershell.exe -WindowStyle Hidden -STA -NoProfile -ExecutionPolicy Bypass -File "Mr. Benkhriza.ps1"
    ) > "!DESKTOP!\Mr. Benkhriza.bat"
    echo  [OK] Fallback launcher created on Desktop.
)
echo.

:: ---------------------------------------------------------------------------
:: Summary
:: ---------------------------------------------------------------------------
cls
echo.
echo  =====================================================
if !DLL_FAIL!==0 (
    echo.
    echo   ####   #####  #####  #  #  #   #   ###    ####   #   #
    echo   #      #        #    #  #  #   #  #   #   #   #  #   #
    echo   ####   ###      #    ####  #   #  #####   ####   #####
    echo   #      #        #    #  #  #   #  #   #   #      #   #
    echo   ####   #####    #    #  #  #####  #   #   #      #   #
    echo.
    echo   SETUP COMPLETE! - Mr. Benkhriza SteamTools v3.1
) else (
    echo   Setup completed with ERRORS - see messages above.
    echo   Try right-clicking Setup.bat and selecting Run as Administrator.
)
echo  =====================================================
echo.
echo  What was installed:
echo    [+] DLLs          -^> !STEAM_PATH!
echo    [+] Lua scripts   -^> !LUA_DIR!
echo    [+] Shortcut      -^> !DESKTOP!\Mr. Benkhriza.lnk
echo.
echo  How to use:
echo    1. Launch "Mr. Benkhriza" from your Desktop
echo    2. Enter your license key when prompted
echo    3. Search for a game and click FETCH LUA or INJECT
echo.
echo  Need help? Visit the GitHub page or contact Benkhriza.
echo.

if !DLL_FAIL!==0 (
    set /p "START_STEAM=  Start Steam now? [Y/N]: "
    if /i "!START_STEAM!"=="Y" (
        echo  [INFO] Starting Steam...
        start "" "!STEAM_PATH!\steam.exe"
    )
)

echo.
echo  Press any key to close...
pause >nul
exit /b 0

:fail_no_steam
echo  [ERROR] Steam not found. Please install Steam first.
echo.
pause
exit /b 1

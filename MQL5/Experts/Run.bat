@echo off
setlocal enabledelayedexpansion
title MetaTrader 5 All-in-One Auto-Compile & Live Trading

echo ========================================================
echo   Exness MT5 All-in-One Auto-Compile & Live Trading
echo ========================================================

set "MT5_PATH=C:\Program Files\MetaTrader 5 - EXNESS"
set "METAEDITOR=%MT5_PATH%\metaeditor64.exe"
set "TERMINAL=%MT5_PATH%\terminal64.exe"
set "PROJECT_DIR=%~dp0"

:: 1. MT5 ચેક કરવું
if not exist "%TERMINAL%" (
    echo [ERROR] MT5 not found at "%MT5_PATH%"!
    echo Please install Exness MT5 first.
    pause
    exit /b 1
)

echo [1/4] Initializing MT5 profile folders...
start "" "%TERMINAL%"
timeout /t 5 /nobreak >nul
taskkill /F /IM terminal64.exe >nul 2>&1
timeout /t 2 /nobreak >nul

echo [2/4] Syncing project files and compiling via MetaEditor...
for /d %%G in ("%APPDATA%\MetaQuotes\Terminal\*") do (
    set "MQL5_TARGET=%%G\MQL5"
    if not exist "!MQL5_TARGET!" mkdir "!MQL5_TARGET!"
    
    :: પ્રોજેક્ટ ફાઇલ્સ MQL5 ફોલ્ડરમાં કોપી કરવી (גיટ / હાઇડન ફોલ્ડર્સ છોડીને)
    xcopy "%PROJECT_DIR%*" "!MQL5_TARGET!\" /E /I /Y /Q 2>nul
    
    :: MetaEditor દ્વારા કમ્પાઈલ કરવું
    if exist "%METAEDITOR%" (
        for /r "!MQL5_TARGET!" %%p in (*.mqproj) do (
            echo Compiling Project: %%p
            "%METAEDITOR%" /compile:"%%p" /log
        )
        for /r "!MQL5_TARGET!\Experts" %%m in (*.mq5) do (
            echo Compiling EA: %%m
            "%METAEDITOR%" /compile:"%%m" /log
        )
    )
)

echo [3/4] Creating Live Trading INI Configuration File...
set "CONFIG_FILE=%PROJECT_DIR%mt5_live_config.ini"
(
echo [Common]
echo Login=434157116
echo Password=Admin&@12345
echo Server=Exness-MT5Trial7
echo.
echo [Community]
echo Login=rinkugohil30897
echo Password=fW4JT5vz
echo.
echo [Experts]
echo AllowLiveTrading=1
echo AllowDllImport=1
echo WebRequest=1
echo WebRequestUrl=https://nfs.faireconomy.media/ff_calendar_thisweek.csv,https://api.fxblue.com/market-data/tools/sentiment
echo.
echo [Startup]
echo Symbol=XAUUSD
echo Period=H1
) > "%CONFIG_FILE%"

echo [4/4] Launching MetaTrader 5 with Configuration...
start "" "%TERMINAL%" "/config:%CONFIG_FILE%"

echo ========================================================
echo   Success! MetaTrader 5 is running with Live Trading.
echo ========================================================
pause

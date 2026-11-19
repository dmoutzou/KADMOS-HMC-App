@echo off
REM ==========================================================================
REM  KADMOS HMC App launcher (Windows). Double-click to start.
REM
REM  - Uses Julia 1.11 (the version the app was built and tested with).
REM  - If Julia 1.11 is not found, downloads it once into the "julia" folder
REM    next to this file (about 270 MB). Nothing is installed elsewhere.
REM  - The first start installs the Julia packages (internet, several minutes).
REM ==========================================================================
setlocal
title KADMOS HMC App
cd /d "%~dp0"
set "APP_DIR=%~dp0"
if "%APP_DIR:~-1%"=="\" set "APP_DIR=%APP_DIR:~0,-1%"
set "JULIA_VERSION=1.11.9"
set "JULIA_CHANNEL=1.11"
set "JULIA_URL=https://julialang-s3.julialang.org/bin/winnt/x64/%JULIA_CHANNEL%/julia-%JULIA_VERSION%-win64.zip"

REM Ready-made bundle (made with build_bundle.bat): use the packages shipped in .\depot.
REM The trailing ";" keeps Julia's own standard-library caches.
if exist "%APP_DIR%\depot\" set "JULIA_DEPOT_PATH=%APP_DIR%\depot;"

echo.
echo   KADMOS HMC App
echo   --------------
echo.

REM 1. Julia downloaded earlier into the app folder
if exist "%APP_DIR%\julia\bin\julia.exe" goto :local_julia

if defined KADMOS_LOCAL_JULIA goto :download
REM 2. Juliaup that already has a Julia 1.11 channel (read from "juliaup status": asking
REM    "julia +1.11" directly would make Juliaup download it when it is not installed)
if exist "%LOCALAPPDATA%\Microsoft\WindowsApps\juliaup.exe" set "PATH=%PATH%;%LOCALAPPDATA%\Microsoft\WindowsApps"
if exist "%USERPROFILE%\.juliaup\bin\juliaup.exe" set "PATH=%PATH%;%USERPROFILE%\.juliaup\bin"
where juliaup >nul 2>nul
if errorlevel 1 goto :check_path_julia
set "JUP_CHANNEL="
for /f "tokens=1-3" %%a in ('juliaup status 2^>nul') do (
    for %%t in (%%a %%b %%c) do (
        echo %%t| findstr /r /x "1\.11 1\.11\.[0-9]*" >nul && set "JUP_CHANNEL=%%t"
    )
)
if not defined JUP_CHANNEL goto :check_path_julia
julia +%JUP_CHANNEL% --startup-file=no -e "exit(VERSION.major == 1 && VERSION.minor == 11 ? 0 : 3)" >nul 2>nul
if errorlevel 1 goto :check_path_julia
set "JULIA=julia +%JUP_CHANNEL%"
goto :run

REM 3. A Julia 1.11 on the PATH
:check_path_julia
where julia >nul 2>nul
if errorlevel 1 goto :download
julia --startup-file=no -e "exit(VERSION.major == 1 && VERSION.minor == 11 ? 0 : 3)" >nul 2>nul
if errorlevel 1 goto :download
set "JULIA=julia"
goto :run

REM 4. Download Julia 1.11 into the app folder (curl and tar are part of Windows 10/11)
:download
echo Julia %JULIA_CHANNEL% was not found on this computer.
echo Downloading Julia %JULIA_VERSION% into the app folder (about 270 MB, once)...
echo.
if exist "%APP_DIR%\julia.download" rmdir /s /q "%APP_DIR%\julia.download"
mkdir "%APP_DIR%\julia.download"
curl.exe -fL --progress-bar -o "%APP_DIR%\julia.download\julia.zip" "%JULIA_URL%"
if errorlevel 1 goto :fail_download
echo Unpacking...
tar.exe -xf "%APP_DIR%\julia.download\julia.zip" -C "%APP_DIR%\julia.download"
if errorlevel 1 goto :fail_download
if exist "%APP_DIR%\julia" rmdir /s /q "%APP_DIR%\julia"
move "%APP_DIR%\julia.download\julia-%JULIA_VERSION%" "%APP_DIR%\julia" >nul
if errorlevel 1 goto :fail_download
rmdir /s /q "%APP_DIR%\julia.download"
echo Julia %JULIA_VERSION% is ready.
echo.

:local_julia
set JULIA="%APP_DIR%\julia\bin\julia.exe"

REM --------------------------------------------------------------------------
:run
echo Keep this window open while you use the app; close it to quit.
echo.
echo TIP: do not click inside this window. Windows pauses the program while text in
echo      the window is selected. If it looks stuck, click here once and press Enter.
echo.
%JULIA% --threads=auto,1 --project="%APP_DIR%" "%APP_DIR%\KADMOS_App.jl" %*
set "RC=%errorlevel%"
echo.
if not defined KADMOS_NO_PAUSE pause
exit /b %RC%

:fail_download
echo.
echo Could not download or unpack Julia %JULIA_VERSION%.
echo Check the internet connection and double-click KADMOS_App.bat again.
echo Or install Julia 1.11 by hand from https://julialang.org/downloads/
if exist "%APP_DIR%\julia.download" rmdir /s /q "%APP_DIR%\julia.download"
pause
exit /b 1

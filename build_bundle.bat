@echo off
REM ==========================================================================
REM  Build a ready-to-run KADMOS HMC App bundle for Windows (64-bit).
REM
REM  Run it once on a Windows 10/11 PC: double-click build_bundle.bat.
REM  It downloads Julia 1.11 into .\julia, installs and precompiles every
REM  package (including the figure packages) into .\depot, and zips the whole
REM  folder to ..\KADMOS_HMC_App-Windows-x64.zip. Users unzip it and start the
REM  app: no Julia download, no package installation, works without internet.
REM ==========================================================================
setlocal
cd /d "%~dp0"
set "APP_DIR=%~dp0"
if "%APP_DIR:~-1%"=="\" set "APP_DIR=%APP_DIR:~0,-1%"
for %%I in ("%APP_DIR%") do set "BASE=%%~nxI"
for %%I in ("%APP_DIR%\..") do set "PARENT=%%~fI"
set "OUT=%PARENT%\KADMOS_HMC_App-Windows-x64.zip"

echo Building KADMOS_HMC_App for Windows x64
if not exist "%APP_DIR%\depot\" mkdir "%APP_DIR%\depot"
set "KADMOS_LOCAL_JULIA=1"
set "KADMOS_NO_PAUSE=1"
REM Compile the packages for a family of processors (as Julia itself is built), not only for this PC
set "JULIA_CPU_TARGET=generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)"
REM An empty home folder while building, so packages already in this PC's .julia folder are not
REM reused (they would then be missing from the bundle)
set "USERPROFILE=%TEMP%\kadmos_bundle_home"
if exist "%USERPROFILE%" rmdir /s /q "%USERPROFILE%"
mkdir "%USERPROFILE%"
call "%APP_DIR%\KADMOS_App.bat" --install-only
if errorlevel 1 (
    echo Package installation failed.
    pause
    exit /b 1
)

if exist "%APP_DIR%\depot\logs" rmdir /s /q "%APP_DIR%\depot\logs"
if exist "%APP_DIR%\plots\install.log" del /q "%APP_DIR%\plots\install.log"

echo Creating %OUT% ...
if exist "%OUT%" del /q "%OUT%"
pushd "%PARENT%"
tar.exe -a -c -f "%OUT%" --exclude "%BASE%/results" --exclude "PTt_params.dat" --exclude "Custom_Diff.dat" "%BASE%"
set "ERR=%errorlevel%"
popd
if not "%ERR%"=="0" (
    echo Could not create the zip file.
    pause
    exit /b 1
)
echo Done: %OUT%
echo Users unzip it (to a short path such as C:\KADMOS) and double-click KADMOS_App.bat.
pause

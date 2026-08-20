@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"

where node >nul 2>nul
if errorlevel 1 goto no_node

echo Checking that Codex and CC-Switch are fully closed...
node "%~dp0install_bulk_codex_migration.mjs" --rollback-latest
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" goto failed
echo.
echo Rollback completed. The post-migration state was also backed up.
pause
exit /b 0

:no_node
echo Node.js was not found. No file was changed.
pause
exit /b 1

:failed
echo.
echo Rollback failed or was blocked by the safety check.
echo Keep the complete error text shown in this window.
pause
exit /b %RESULT%

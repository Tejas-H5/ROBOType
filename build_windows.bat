@echo off

SET VERSION=v1.0.0

SET OUTPUT_DIR=build\windows\output
SET BUILDS_DIR=build\windows\

rmdir /s /q %OUTPUT_DIR%
md %OUTPUT_DIR%
if %errorlevel% neq 0 (
    echo Task failed with error %errorlevel%
    exit /b %errorlevel%
)

odin build . -o:speed -out:%OUTPUT_DIR%\ROBOType.exe
if %errorlevel% neq 0 (
    echo Task failed with error %errorlevel%
    exit /b %errorlevel%
)

md %OUTPUT_DIR%\collections
robocopy .\collections .\%OUTPUT_DIR%\collections /s /e
REM https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/robocopy#exit-return-codes
if %errorlevel% GEQ 8 (
    echo Task failed with error %errorlevel%
    exit /b %errorlevel%
)
md %OUTPUT_DIR%\collections
robocopy .\font .\%OUTPUT_DIR%\font /s /e
REM https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/robocopy#exit-return-codes
if %errorlevel% GEQ 8 (
    echo Task failed with error %errorlevel%
    exit /b %errorlevel%
)

powershell -C "Compress-Archive -Path %OUTPUT_DIR% -DestinationPath %BUILDS_DIR%\ROBOType-windows-%VERSION%.zip"
if %errorlevel% neq 0 (
    echo Task failed with error %errorlevel%
    exit /b %errorlevel%
)

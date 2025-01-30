@echo off

set GAME_RUNNING=false
for /f %%x in ('tasklist /NH /FI "IMAGENAME eq game.exe"') do if %%x == game.exe set GAME_RUNNING=true

if %GAME_RUNNING% == false (
	del /q /s bin\hot_reload >nul 2>nul
	echo 0 > bin\hot_reload\pdb_number
)

set /p PDB_NUMBER=<bin\hot_reload\pdb_number
set /a PDB_NUMBER=%PDB_NUMBER%+1
echo %PDB_NUMBER% > bin\hot_reload\pdb_number

sokol-shdc -i src/simgui/shader.glsl -o src/simgui/shader.odin -l hlsl4 -f sokol_odin

odin build src -debug -define:SOKOL_DLL=true -build-mode:dll -out:bin/hot_reload/game.dll -pdb-name:bin/hot_reload/game_%PDB_NUMBER%.pdb
if %ERRORLEVEL% NEQ 0 exit /b 1

if %GAME_RUNNING% == true (
	echo Reloading game.dll && exit /b 0
)

odin build src/main -debug -define:SOKOL_DLL=true -out:bin/game.exe
if %ERRORLEVEL% NEQ 0 exit /b 1

if "%~1"=="run" (
	bin\game.exe
)
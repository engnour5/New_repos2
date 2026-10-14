@echo off
rem Builds the app from this folder (src_file) and puts the ready-to-run app in ..\App_file, with the Visual C++
rem runtime, so App_file runs on any Windows 10/11 x64 PC. Flutter and Git live in D:\Tools (no admin rights needed).
setlocal
set "PATH=D:\Tools\flutter\bin;D:\Tools\MinGit\cmd;%PATH%"
cd /d "%~dp0"
rem --no-tree-shake-icons: always ship the full icon font (a cut-down font from an older build once left new icons blank)
call flutter build windows --release --no-tree-shake-icons || goto :fail

set "OUT=%~dp0..\App_file"
if not exist "%OUT%" mkdir "%OUT%"
rem replace only the app's own files; anything else you keep in App_file stays
if exist "%OUT%\data" rmdir /s /q "%OUT%\data"
del /q "%OUT%\*.exe" "%OUT%\*.dll" "%OUT%\native_assets.json" 2>nul
xcopy /e /i /q /y "build\windows\x64\runner\Release\*" "%OUT%\" >nul || goto :fail

set "CRT="
for /d %%D in ("C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Redist\MSVC\*") do (
  if exist "%%D\x64\Microsoft.VC143.CRT\msvcp140.dll" set "CRT=%%D\x64\Microsoft.VC143.CRT"
)
if defined CRT (
  copy /y "%CRT%\msvcp140.dll" "%OUT%\" >nul
  copy /y "%CRT%\vcruntime140.dll" "%OUT%\" >nul
  copy /y "%CRT%\vcruntime140_1.dll" "%OUT%\" >nul
) else (
  echo Note: Visual C++ runtime not found; the PC that runs the app needs the VC++ 2015-2022 redistributable.
)
for %%F in ("%OUT%") do echo Built "%%~fF\iphone_nfc_tester.exe"
exit /b 0

:fail
echo BUILD FAILED
exit /b 1

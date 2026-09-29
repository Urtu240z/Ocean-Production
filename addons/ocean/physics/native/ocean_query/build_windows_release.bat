@echo off
setlocal
set "ROOT=%~dp0"
if not defined GODOT_CPP_PATH set "GODOT_CPP_PATH=%ROOT%..\godot-cpp"
if not exist "%GODOT_CPP_PATH%\SConstruct" (
  echo [FAIL] Missing godot-cpp at "%GODOT_CPP_PATH%".
  echo Set up Godot 4.7 godot-cpp there, or set GODOT_CPP_PATH before running this script.
  exit /b 2
)
where python >nul 2>nul || (echo [FAIL] Python 3 is required.& exit /b 2)
where cl >nul 2>nul
if errorlevel 1 (
  if defined VSINSTALLDIR (
    call "%VSINSTALLDIR%\VC\Auxiliary\Build\vcvars64.bat"
  ) else (
    echo [FAIL] MSVC x64 compiler is unavailable. Run from a VS Developer Command Prompt.
    exit /b 2
  )
)
pushd "%ROOT%"
python -m SCons platform=windows target=template_release "godot_cpp_path=%GODOT_CPP_PATH%"
set "BUILD_RESULT=%ERRORLEVEL%"
popd
if not "%BUILD_RESULT%"=="0" exit /b %BUILD_RESULT%
echo [OK] Windows x86_64 Release extension built.
endlocal

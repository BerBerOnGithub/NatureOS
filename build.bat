@echo off
REM ===========================================================================
REM build.bat - ClaudeOS Build Script (ISO edition)
REM Requires: nasm, python + pycdlib (pip install pycdlib)
REM ===========================================================================
setlocal

if /i "%~1"=="clean" goto :clean

REM - strip BOMs from all source files before doing anything else -
echo [0/6] Stripping BOMs...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bom.ps1" >nul 2>&1

REM - find NASM -
set "NASM=nasm"
where nasm >nul 2>&1
if errorlevel 1 (
    if exist "%~dp0nasm.exe" ( set "NASM=%~dp0nasm.exe" ) else (
        echo ERROR: nasm not found. & pause & exit /b 1
    )
)

REM - check pycdlib -
python -c "import pycdlib" >nul 2>&1
if errorlevel 1 (
    echo pycdlib not found - installing...
    pip install pycdlib
    if errorlevel 1 ( echo ERROR: pip install pycdlib failed & exit /b 1 )
)

if not exist build md build

echo [1/6] Assembling stage 1...
"%NASM%" -f bin -o build\boot.bin boot.asm
if errorlevel 1 ( echo FAILED: boot.asm & exit /b 1 )
for %%F in (build\boot.bin) do set S=%%~zF
if not "%S%"=="512" ( echo ERROR: boot.bin must be 512 bytes & exit /b 1 )
echo  OK  boot.bin [512 bytes]

echo [2/6] Assembling stage 2...
"%NASM%" -f bin -o build\stage2.bin stage2.asm
if errorlevel 1 ( echo FAILED: stage2.asm & exit /b 1 )
REM stage2 sits in 512-LBA 1-3 (3 sectors = 1536 bytes max, before kernel at LBA 4)
for %%F in (build\stage2.bin) do set S2=%%~zF
echo  OK  stage2.bin [%S2% bytes]
REM Check stage2 fits in 3 sectors (1536 bytes)
powershell -NoProfile -Command "if ((Get-Item 'build\stage2.bin').Length -gt 1536) { Write-Host 'ERROR: stage2.bin exceeds 1536 bytes - will overwrite kernel LBA 4!'; exit 1 }"
if errorlevel 1 ( echo FAILED: stage2 too large & exit /b 1 )

echo [3/6] Assembling kernel...
"%NASM%" -f bin -o build\kernel.bin kernel.asm
if errorlevel 1 ( echo FAILED: kernel.asm & exit /b 1 )
for %%F in (build\kernel.bin) do echo  OK  kernel.bin [%%~zF bytes]

echo [4/6] Packing filesystem...
python mkfs.py
if errorlevel 1 ( echo FAILED: mkfs.py & exit /b 1 )

echo [4b] Creating data disk image...
python mkdata.py
if errorlevel 1 ( echo FAILED: mkdata.py & exit /b 1 )

echo [5/6] Building flat binary image...
REM Layout aligned to 2048-byte CD sectors (4 x 512-byte sectors):
REM   512-sector 0:   boot.bin
REM   512-sector 1:   stage2.bin   (max 3 sectors = 1536 bytes)
REM   512-sector 4:   kernel.bin   (2048-LBA 1)
REM   512-sector 204: fs.bin       (2048-LBA 51)
set KERNEL_SECTOR=4
set FS_SECTOR=204
set FS_SECTORS=1600
set /a FLAT_SECTORS=%FS_SECTOR%+%FS_SECTORS%
set /a FLAT_BYTES=%FLAT_SECTORS%*512
set /a FS_OFFSET=%FS_SECTOR%*512
set /a KERN_OFFSET=%KERNEL_SECTOR%*512

set "PS1=%TEMP%\claudeos_build.ps1"
(
    echo $flat   = New-Object byte[] ^(%FLAT_BYTES%^)
    echo $boot   = [IO.File]::ReadAllBytes^('build\boot.bin'^)
    echo $stage2 = [IO.File]::ReadAllBytes^('build\stage2.bin'^)
    echo $kern   = [IO.File]::ReadAllBytes^('build\kernel.bin'^)
    echo $fs     = [IO.File]::ReadAllBytes^('build\fs.bin'^)
    echo [Array]::Copy^($boot,   0, $flat,             0, $boot.Length^)
    echo [Array]::Copy^($stage2, 0, $flat,           512, $stage2.Length^)
    echo [Array]::Copy^($kern,   0, $flat, %KERN_OFFSET%, $kern.Length^)
    echo [Array]::Copy^($fs,     0, $flat,   %FS_OFFSET%, $fs.Length^)
    echo [IO.File]::WriteAllBytes^('build\claudeos_flat.img', $flat^)
    echo Write-Host ' OK  claudeos_flat.img'
) > "%PS1%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
del "%PS1%" >nul 2>&1
if errorlevel 1 ( echo FAILED: flat image creation & exit /b 1 )

echo [6/6] Building ISO...
python mkiso.py
if errorlevel 1 ( echo FAILED: mkiso.py & exit /b 1 )

echo.
echo ================================
echo   claudeos.iso built!
echo ================================
echo.
echo   Boot paths supported:
echo     CD/DVD  -^> El Torito no-emulation
echo     USB     -^> Hybrid MBR (Rufus DD mode / Etcher / dd)
echo     CSM     -^> Both paths work via BIOS INT 13h
echo.

if /i "%~1"=="run" goto :run
exit /b 0

:run
qemu-system-x86_64 ^
  -cdrom claudeos.iso ^
  -drive format=raw,file=data.img,if=ide,index=3 ^
  -boot d ^
  -m 64M ^
  -cpu qemu64 ^
  -smp 1 ^
  -vga std ^
  -rtc base=localtime ^
  -audiodev id=snd,driver=dsound ^
  -machine pcspk-audiodev=snd ^
  -nic user,model=e1000 ^
  -display sdl,window-close=on ^
  -name "ClaudeOS" ^
  -no-reboot
exit /b 0

:clean
echo Cleaning...
if exist build\boot.bin          del /q build\boot.bin
if exist build\stage2.bin        del /q build\stage2.bin
if exist build\kernel.bin        del /q build\kernel.bin
if exist build\fs.bin            del /q build\fs.bin
if exist build\claudeos_flat.img del /q build\claudeos_flat.img
if exist claudeos.iso            del /q claudeos.iso
if exist build                   rd build
echo Done.
exit /b 0

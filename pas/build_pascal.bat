@echo off
chcp 65001 >nul
rem Сборка FreePascal-версии модулей FB2 (Windows).
rem Требуется fpc.exe в PATH (или укажите полный путь в строке ниже).
set "PATH=C:\app\lazarus\fpc\3.2.2\bin\x86_64-win64;%PATH%"
set FPC=fpc
set FPCFLAGS=-Mobjfpc -Sh -O2 -vw

echo === Сборка fb2parser_cli ===
%FPC% %FPCFLAGS% fb2parser_cli.pas
if errorlevel 1 goto error

echo === Сборка fb2markdown_cli ===
%FPC% %FPCFLAGS% fb2markdown_cli.pas
if errorlevel 1 goto error

echo === Сборка fb2writer_cli ===
%FPC% %FPCFLAGS% fb2writer_cli.pas
if errorlevel 1 goto error

echo === Сборка fb2html_cli ===
%FPC% %FPCFLAGS% fb2html_cli.pas
if errorlevel 1 goto error

echo === Сборка fb2index_cli ===
%FPC% %FPCFLAGS% fb2index_cli.pas
if errorlevel 1 goto error

echo === Сборка fb2splitmerge_cli ===
%FPC% %FPCFLAGS% fb2splitmerge_cli.pas
if errorlevel 1 goto error

echo === Сборка fb2normalizer_cli ===
%FPC% %FPCFLAGS% fb2normalizer_cli.pas
if errorlevel 1 goto error

echo === Сборка fb2txt_cli ===
%FPC% %FPCFLAGS% fb2txt_cli.pas
if errorlevel 1 goto error

echo === Сборка fb2epub_cli ===
%FPC% %FPCFLAGS% fb2epub_cli.pas
if errorlevel 1 goto error

echo === Сборка fb2fromepub_cli ===
%FPC% %FPCFLAGS% fb2fromepub_cli.pas
if errorlevel 1 goto error

echo === Сборка fb2tofb3_cli ===
%FPC% %FPCFLAGS% fb2tofb3_cli.pas
if errorlevel 1 goto error

echo === Сборка fb3tofb2_cli ===
%FPC% %FPCFLAGS% fb3tofb2_cli.pas
if errorlevel 1 goto error

echo === Сборка fb2todocx_cli ===
%FPC% %FPCFLAGS% fb2todocx_cli.pas
if errorlevel 1 goto error

echo === Сборка docxtofb2_cli ===
%FPC% %FPCFLAGS% docxtofb2_cli.pas
if errorlevel 1 goto error

echo === Сборка fb2toodt_cli ===
%FPC% %FPCFLAGS% fb2toodt_cli.pas
if errorlevel 1 goto error

echo === Сборка odttofb2_cli ===
%FPC% %FPCFLAGS% odttofb2_cli.pas
if errorlevel 1 goto error

echo === Сборка htmltofb2_cli ===
%FPC% %FPCFLAGS% htmltofb2_cli.pas
if errorlevel 1 goto error

echo === Сборка fb2tomobi_cli ===
%FPC% %FPCFLAGS% fb2tomobi_cli.pas
if errorlevel 1 goto error

echo === Сборка mobitofb2_cli ===
%FPC% %FPCFLAGS% mobitofb2_cli.pas
if errorlevel 1 goto error

echo === Сборка markdowntofb2_cli ===
%FPC% %FPCFLAGS% markdowntofb2_cli.pas
if errorlevel 1 goto error

echo.
echo Готово: fb2parser_cli.exe, fb2markdown_cli.exe, fb2writer_cli.exe, fb2html_cli.exe, fb2index_cli.exe, fb2splitmerge_cli.exe, fb2normalizer_cli.exe, fb2txt_cli.exe, fb2epub_cli.exe, fb2fromepub_cli.exe, fb2tofb3_cli.exe, fb3tofb2_cli.exe, fb2todocx_cli.exe, docxtofb2_cli.exe, fb2toodt_cli.exe, odttofb2_cli.exe, htmltofb2_cli.exe, fb2tomobi_cli.exe, mobitofb2_cli.exe, markdowntofb2_cli.exe
del *.ppu 2>nul
del *.o 2>nul
goto :eof

:error
echo.
echo Ошибка сборки. Проверьте, что FreePascal установлен и доступен в PATH.
exit /b 1

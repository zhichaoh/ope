
set VCINSTALLDIR=C:\Program Files (x86)\Microsoft Visual Studio\2017\Enterprise\VC\
rem set VCINSTALLDIR=C:\Program Files (x86)\Microsoft Visual Studio\2017\Professional\VC\

rem set VCToolsRedistDir="C:\Program Files (x86)\Microsoft Visual Studio\2017\Enterprise\VC\Redist\MSVC\14.15.26706\"

cd build-OPE_LMS-Desktop_Qt_5_12_0_MSVC2017_64bit-Release\release

C:\Qt\Qt5.12.0\5.12.0\msvc2017_64\bin\windeployqt.exe --compiler-runtime --qmldir ../../OPE_LMS --angle OPE_LMS.exe
rem c:\Qt\5.12.0\msvc2017_64\bin\windeployqt.exe --compiler-runtime --qmldir ../../OPE_LMS --angle OPE_LMS.exe
rem C:\Qt\5.11.2\msvc2017_64\qml

REM NOTE - Need to move resources/* to release folder
xcopy /YI resources .
REM NOTE - Need to move translations/qtwebengine_locales to release folder
xcopy /YI "translations/qtwebengine_locales" "./qtwebengine_locales"

cd ..\..

echo Done Building!!!!
pause

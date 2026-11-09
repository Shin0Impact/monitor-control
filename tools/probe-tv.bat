@echo off
rem Finds how your Android TV names its HDMI inputs and what it is showing.
rem Usage: probe-tv.bat 10.0.0.222 hdmi   (while the TV shows the PC)   -> writes tv-probe-hdmi.txt
rem        probe-tv.bat 10.0.0.222 yt     (while the TV shows YouTube) -> writes tv-probe-yt.txt
rem Look in the output for "inputId: ...HW15" (your PC's input) and the "mCurrentFocus" package (the TV app).
set T=%1:5555
set OUT=%~dp0tv-probe-%2.txt
adb connect %T% > "%OUT%" 2>&1
echo ==== focus >> "%OUT%"
adb -s %T% shell "dumpsys window | grep -E 'mCurrentFocus|mFocusedApp'" >> "%OUT%" 2>&1
echo ==== resumed >> "%OUT%"
adb -s %T% shell "dumpsys activity activities | grep -E 'mResumedActivity|topResumedActivity'" >> "%OUT%" 2>&1
echo ==== tv_input >> "%OUT%"
adb -s %T% shell "dumpsys tv_input | head -150" >> "%OUT%" 2>&1
echo Done - saved %OUT%
pause

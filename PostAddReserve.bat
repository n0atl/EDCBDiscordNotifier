@echo off
chcp 932 > nul

rem // ウインドウを非表示にする
rem _EDCBX_HIDE_

rem // パラメータを環境変数に渡す
rem // こうすることで Python 側でも環境変数を参照できる
rem _EDCBX_DIRECT_

rem // 視聴予約なら終了
if "%RecMode%" == "4" (
    goto :eof
)

rem // Discordに通知させる
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0EDCBNotifier_Discord-only\EDCBNotifier_Discord.ps1" PostAddReserve

exit
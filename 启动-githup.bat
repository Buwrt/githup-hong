@echo off
chcp 65001 >nul
REM ============================================================
REM  githup 桌面版 —— Windows 启动脚本
REM  双击即可：起本地服务 → 自动打开浏览器
REM  需要电脑已安装 Node.js 18 或更高版本（nodejs.org）
REM ============================================================

where node >nul 2>nul
if errorlevel 1 (
  echo.
  echo   没检测到 Node.js。
  echo   请先到 https://nodejs.org 下载安装（一路下一步即可），然后重新双击本文件。
  echo.
  pause
  exit /b 1
)

cd /d "%~dp0"
node server.js
pause

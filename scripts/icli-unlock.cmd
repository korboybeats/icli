@echo off
wsl.exe -d Ubuntu --exec /home/korboy-wsl/bin/icli-unlock %*
exit /b %errorlevel%

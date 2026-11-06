@echo off
cd /d "%~dp0"
echo run %date% %time% > send-log.txt
git add -A >> send-log.txt 2>&1
git -c user.name=ALFRED -c user.email=azabooalfred-a11y@users.noreply.github.com commit -m "Update" >> send-log.txt 2>&1
git push >> send-log.txt 2>&1
echo done >> send-log.txt

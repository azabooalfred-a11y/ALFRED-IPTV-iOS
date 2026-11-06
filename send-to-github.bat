@echo off
cd /d "%~dp0"
title ALFRED-IPTV iOS - send to GitHub
where git >/dev/null 2>nul
if errorlevel 1 (
  echo Git is not installed. Install it from https://git-scm.com/download/win then run this again.
  pause
  exit /b
)
if not exist .git (
  git init -b main
  git add -A
  git -c user.name=ALFRED -c user.email=azabooalfred-a11y@users.noreply.github.com commit -m "ALFRED-IPTV for iPhone"
  gh repo create azabooalfred-a11y/ALFRED-IPTV-iOS --public --source . --remote origin --push
) else (
  git add -A
  git -c user.name=ALFRED -c user.email=azabooalfred-a11y@users.noreply.github.com commit -m "Update"
  git push
)
echo.
echo Done. The iPhone app is now building on GitHub (about 10 minutes).
echo https://github.com/azabooalfred-a11y/ALFRED-IPTV-iOS/actions
pause

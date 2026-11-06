@echo off
title ALFRED-IPTV - download iPhone app
gh release download latest -R azabooalfred-a11y/ALFRED-IPTV-iOS -p ALFRED-IPTV.ipa -D "%USERPROFILE%\Desktop" --clobber > "%~dp0get-ipa-log.txt" 2>&1
dir "%USERPROFILE%\Desktop\ALFRED-IPTV.ipa" >> "%~dp0get-ipa-log.txt" 2>&1

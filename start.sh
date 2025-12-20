#!/bin/bash

# Sentinel Startup Script
# Updates system, starts PM2 server, and launches Chromium in Kiosk mode.

# 1. Ensure PM2 Server is running (It should be via pm2 startup, but good to ensure)
# We assume the user environment is set up.
# export PATH=$PATH:/home/develop/.nvm/versions/node/v22.21.1/bin # Example, might not be needed if in .bashrc

echo "Starting Sentinel System..."

# 2. Launch Chromium Kiosk
# Flags explained:
# --noerrdialogs: Suppress error dialogs (crashes etc)
# --disable-infobars: Remove "Chrome is being controlled by test software"
# --kiosk: Fullscreen kiosk mode
# --check-for-update-interval=31536000: Disable update checks (1 year)
# --disable-translate: Disable translation popups
# --disable-restore-session-state: Prevent "Restore pages?" bubble after crash
# --autoplay-policy=no-user-gesture-required: Allow video/audio autoplay immediately
# --incognito: Clean session every time (Optional, good for kiosk to avoid cache issues)

# --disable-features=UseChromeOSDirectVideoDecoder: Fixes some V4L2 errors on RPi
# --disable-dev-shm-usage: Fixes crash in low-memory/docker environments
# --no-sandbox: Sometimes needed if permissions are weird (try to avoid if possible, but adding for stability)

/usr/bin/chromium-browser \
    --noerrdialogs \
    --disable-infobars \
    --kiosk \
    --check-for-update-interval=31536000 \
    --disable-translate \
    --disable-restore-session-state \
    --autoplay-policy=no-user-gesture-required \
    --incognito \
    --disable-features=UseChromeOSDirectVideoDecoder \
    --disable-dev-shm-usage \
    http://localhost:3000/kiosk/index.html &


echo "Chromium Launched."

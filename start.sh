#!/bin/bash

# Define paths
APP_DIR="$(dirname "$0")"
export DISPLAY=:0

# 1. Start Node Server (using PM2 to ensure it's alive, or just check)
# We assume PM2 is managing the server as per install.sh, but let's ensure it's started.
# If using pm2, we don't need to start it here explicitly if 'pm2 startup' was used.
# But user requested "start.sh que ejecute el servidor y abra chromium".

echo "Starting/Restarting Sentinel Server..."
# Check if pm2 is installed
if command -v pm2 &> /dev/null
then
    pm2 restart sentinel-server || pm2 start "$APP_DIR/src/server.js" --name sentinel-server
else
    # Fallback if PM2 is missing
    node "$APP_DIR/src/server.js" > "$APP_DIR/sentinel.log" 2>&1 &
fi

# Wait a moment for server to be ready
sleep 3

# 2. Start Chromium in Kiosk Mode
# Flags:
# --kiosk: Fullscreen/Lock
# --noerrdialogs: Suppress crash dialogs
# --disable-infobars: Remove "Chrome is being controlled..."
# --disable-features=Translate: Remove translation popup
# --check-for-update-interval=31536000: Stop update checks
# --disable-pinch: Disable touch pinch zoom
# --overscroll-history-navigation=0: Disable swipe nav

echo "Launching Kiosk..."
/usr/bin/chromium-browser \
    --kiosk \
    --noerrdialogs \
    --disable-infobars \
    --disable-features=Translate \
    --check-for-update-interval=31536000 \
    --disable-pinch \
    --overscroll-history-navigation=0 \
    http://localhost:3000/kiosk/index.html &

# Hide cursor (unclutter) - optional, might not be installed
if command -v unclutter &> /dev/null
then
    unclutter -idle 0.1 -root &
fi

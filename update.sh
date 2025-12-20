#!/bin/bash

# Sentinel Update Script
# Usage: ./update.sh

echo "Stashing local changes..."
git stash

echo "Pulling latest changes..."
git pull

echo "Updating dependencies..."
npm install

echo "Restarting Server..."
# Assuming PM2 is managing the process named 'sentinel-server'
if command -v pm2 &> /dev/null
then
    pm2 restart sentinel-server
else
    # Fallback if running with nohup
    pkill -f "node src/server.js"
    nohup node src/server.js > sentinel.log 2>&1 &
fi

echo "Update Complete. NOTE: You might need to reload the Kiosk browser manually or reboot."

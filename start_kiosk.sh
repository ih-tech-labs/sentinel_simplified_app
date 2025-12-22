#!/bin/bash

# Configuration
URL="http://localhost:3000/kiosk/index.html"
SCRIPTS_DIR="/home/pi/SentinelApp/scripts"
GPIO_SCRIPT="$SCRIPTS_DIR/GPIO_control.py"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Function to turn on lights
function turn_on_lights() {
    echo -e "${GREEN}💡 Encendiendo luces blancas...${NC}"
    white_lights="0,0,0,255,0,0,0,0"
    
    # Check if script exists
    if [ -f "$GPIO_SCRIPT" ]; then
        python3 "$GPIO_SCRIPT" "$white_lights" 2>/dev/null || {
            echo -e "${YELLOW}   ⚠️  No se pudieron encender las luces (Arduino desconectado?)${NC}"
        }
    else
         echo -e "${YELLOW}   ⚠️  Script de luces no encontrado en $GPIO_SCRIPT${NC}"
    fi
}

# 0. Ensure Server is Running (PM2)
# If systemd failed, this tries to bring it up.
pm2 resurrect 2>/dev/null || pm2 start /home/pi/SentinelApp/src/server.js --name "sentinel-server"

# 1. Turn on Lights
turn_on_lights

# 2. Prevent Screen Blanking (Display Power Management Signaling)
xset s noblank
xset s off
xset -dpms

# 3. Clean Chromium Session (Prevent "Restore" bubbles)
sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' ~/.config/chromium/Default/Preferences
sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/' ~/.config/chromium/Default/Preferences

# 4. Launch Chromium in Kiosk Mode
# --kiosk: Fullscreen, no borders
# --noerrdialogs: Suppress error dialogs
# --disable-infobars: Remove "Chrome is being controlled..."
# --check-for-update-interval=31536000: Disable updates
# --disable-translate: Disable translation prompt
# --incognito: Don't save history/cache (Optional, good for kiosk)
echo -e "${GREEN}🚀 Iniciando Sentinel Kiosk...${NC}"

chromium-browser --kiosk --noerrdialogs --disable-infobars --check-for-update-interval=31536000 --disable-translate --no-first-run --fast --fast-start --disable-features=TranslateUI --disk-cache-dir=/dev/null --disk-cache-size=1 --start-maximized --disable-session-crashed-bubble "$URL"

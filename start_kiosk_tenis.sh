#!/bin/bash

# Configuration
# ⚠️ IMPORTANTE: Si este Kiosco NO corre el servidor localmente, 
# cambia 'localhost' por la IP de la RPi Admin o el dominio (ej: sentinel.ihtechlabs.com)
URL="http://localhost:3000/kiosk/?id=tenis"

SCRIPTS_DIR="/home/develop/sentinel_simplified_app/scripts"
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

# 1. Turn on Lights
turn_on_lights

# 2. Prevent Screen Blanking
xset s noblank
xset s off
xset -dpms

# 3. Clean Chromium Session
sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' ~/.config/chromium/Default/Preferences
sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/' ~/.config/chromium/Default/Preferences

# 4. Launch Chromium
# Solo navegador, sin servidor local.
echo -e "${GREEN}🚀 Iniciando Sentinel Kiosk (Cliente: Tenis)...${NC}"

chromium-browser --kiosk --noerrdialogs --disable-infobars --check-for-update-interval=31536000 --disable-translate --no-first-run --fast --fast-start --disable-features=TranslateUI --disk-cache-dir=/dev/null --disk-cache-size=1 --start-maximized --disable-session-crashed-bubble "$URL"

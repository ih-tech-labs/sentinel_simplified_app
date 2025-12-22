#!/bin/bash

# Sentinel App Installer for Raspberry Pi
# Run this script on the RPi to setup the environment

echo "Checking dependencies..."

# Update System
sudo apt-get update

# Install Node.js if not present
if ! command -v node &> /dev/null
then
    echo "Node.js could not be found, installing..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
else
    echo "Node.js is already installed."
fi

# Install Git if not present (optional if we are just copying files)
# sudo apt-get install -y git

echo "Installing System Dependencies..."
sudo apt-get install -y ffmpeg

# CLOUDFLARE INSTALLATION
echo "Installing Cloudflared..."
if ! command -v cloudflared &> /dev/null
then
    ARCH=$(dpkg --print-architecture)
    if [ "$ARCH" = "arm64" ]; then
        URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb"
    else
        URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-armhf.deb"
    fi
    curl -L --output cloudflared.deb $URL
    sudo dpkg -i cloudflared.deb
    rm cloudflared.deb
else
    echo "Cloudflared is already installed."
fi

# CLOUDFLARE CONFIGURATION RESTORE
# Moves credentials from user home (if manually authed) to system folder
echo "Checking for Cloudflare credentials in home..."
if [ -d "$HOME/.cloudflared" ]; then
    echo "Found local credentials. Moving to /etc/cloudflared (Requires SUDO)..."
    sudo mkdir -p /etc/cloudflared
    sudo cp -n $HOME/.cloudflared/*.json /etc/cloudflared/ 2>/dev/null || true
    
    # Create Config for Sentinel if not exists
    if [ ! -f "/etc/cloudflared/config.yml" ]; then
        echo "Creating config.yml..."
        # Finds the first JSON file to use as credential
        CRED_FILE=$(ls /etc/cloudflared/*.json | head -n 1)
        if [ -n "$CRED_FILE" ]; then
            UUID=$(basename "$CRED_FILE" .json)
            sudo tee /etc/cloudflared/config.yml > /dev/null <<EOF
tunnel: $UUID
credentials-file: $CRED_FILE
ingress:
  - hostname: sentinel.ihtechlabs.com
    service: http://localhost:3000
  - service: http_status:404
EOF
            echo "Config created for Tunnel ID: $UUID"
        fi
    fi

    # Install Service
    echo "Installing Cloudflared Service..."
    sudo cloudflared service install 2>/dev/null || true
    sudo systemctl restart cloudflared
else
    echo "No local credentials found. Please run 'cloudflared tunnel login' manually if this is a fresh install."
fi

# Create Project Directory if it doesn't exist
# We assume the script is in the project root or we are moving it there.
# For this script, let's assume we are INSIDE the project folder already (e.g. pulled from git or copied)
# So we just install dependencies.

echo "Installing project dependencies..."
npm install

echo "Setting up autostart..."
# We can use PM2 or a Systemd service. PM2 is easier for Node.
echo "Setting up autostart..."
# Try to install PM2 if not found
if ! command -v pm2 &> /dev/null
then
    echo "PM2 not found. Installing..."
    # 1. Try installing globally without sudo (Works for NVM)
    npm install -g pm2
    
    # 2. If that failed, and we still don't have pm2, try with sudo but finding npm first
    if ! command -v pm2 &> /dev/null
    then
        echo "Trying sudo npm install..."
        NPM_PATH=$(which npm)
        if [ -n "$NPM_PATH" ]; then
            sudo "$NPM_PATH" install -g pm2
        else
            echo "Could not find npm to run with sudo."
        fi
    fi
fi

# Check if PM2 is installed now
if command -v pm2 &> /dev/null
then
    echo "PM2 installed successfully."
    pm2 startup
    pm2 start src/server.js --name sentinel-server
    pm2 save
else
    echo "WARNING: PM2 installation failed. Starting server directly in background."
    # Fallback to simple background process
    nohup node src/server.js > sentinel.log 2>&1 &
fi


echo "Server Setup Complete."

# Configuration
INSTALL_DIR="/home/develop/sentinel_simplified_app"
AUTOSTART_DIR="/home/develop/.config/autostart"

echo -e "${YELLOW}📂 Directorio de instalación: $INSTALL_DIR${NC}"

# ... (Previous dependencies install sections remain the same) ...

# 5. Setup Scripts & Assets
echo -e "${YELLOW}🛠️  Configurando Scripts...${NC}"
mkdir -p "$INSTALL_DIR/scripts"

# Move GPIO Script if exists in assets
if [ -f "$INSTALL_DIR/public/assets/GPIO_control.py" ]; then
    cp "$INSTALL_DIR/public/assets/GPIO_control.py" "$INSTALL_DIR/scripts/"
    echo -e "${GREEN}   ✅ GPIO Control script movido correctamente.${NC}"
elif [ -f "$INSTALL_DIR/scripts/GPIO_control.py" ]; then
     echo -e "${GREEN}   ✅ GPIO Control script ya existe en scripts/.${NC}"
else
    echo -e "${YELLOW}   ⚠️  GPIO_control.py no encontrado.${NC}"
fi

# Make startup script executable
chmod +x "$INSTALL_DIR/start_kiosk.sh"


# 6. Configure Autostart (LXDE)
echo -e "${YELLOW}🖥️  Configurando Autostart...${NC}"
mkdir -p "$AUTOSTART_DIR"

cat > "$AUTOSTART_DIR/sentinel.desktop" <<EOL
[Desktop Entry]
Type=Application
Name=Sentinel Kiosk
Exec=$INSTALL_DIR/start_kiosk.sh
StartupNotify=false
Terminal=false
Hidden=false
EOL

echo -e "${GREEN}   ✅ Autostart configurado para ejecutar start_kiosk.sh${NC}"

# 7. Configure PM2 for Server
echo -e "${YELLOW}⚙️  Configurando PM2...${NC}"
cd "$INSTALL_DIR"
pm2 start src/server.js --name "sentinel-server"
pm2 save

echo -e "${BLUE}==============================================${NC}"
echo -e "${GREEN}   INSTALACIÓN COMPLETADA EXITOSAMENTE 🚀${NC}"
echo -e "${BLUE}==============================================${NC}"
echo -e "Para finalizar:"
echo -e "1. Ejecuta: ${YELLOW}pm2 startup${NC} y sigue las instrucciones para que el servidor inicie al boot."
echo -e "2. Reinicia la Raspberry Pi: ${YELLOW}sudo reboot${NC}"

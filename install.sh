#!/bin/bash

# Sentinel App Installer for Raspberry Pi
# Run this script on the RPi to setup the environment

echo "Checking dependencies..."

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

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

# CLOUDFLARE CONFIGURATION (AGREESIVE RESET)
echo "------------------------------------------------"
echo "♻️  Reiniciando configuración de Cloudflare (Modo: Destruir y Recrear)..."

# 0. Check Login (cert.pem)
if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
    echo -e "${RED}❌ Error: No estás logueado en Cloudflare.${NC}"
    echo -e "${YELLOW}Por favor ejecuta: ${GREEN}cloudflared tunnel login${YELLOW} y autoriza el dominio.${NC}"
    echo "Luego vuelve a correr este instalador."
    exit 1
fi

echo -e "${GREEN}✅ Credenciales de usuario detectadas.${NC}"

# 1. Stop and Clean Service
echo "Deteniendo servicios anteriores..."
sudo systemctl stop cloudflared 2>/dev/null
sudo cloudflared service uninstall 2>/dev/null
# Clean /etc/cloudflared to be sure
sudo rm -rf /etc/cloudflared/*.json
sudo rm -rf /etc/cloudflared/*.yml
sudo rm -rf /etc/cloudflared/*.pem

# 2. Delete existing tunnel if exists
TUNNEL_NAME="sentinel"
if cloudflared tunnel list | grep -q "$TUNNEL_NAME"; then
    echo "Eliminando túnel anterior '$TUNNEL_NAME'..."
    cloudflared tunnel delete -f "$TUNNEL_NAME"
fi

# 3. Create Tunnel
echo "Creando nuevo túnel '$TUNNEL_NAME'..."
cloudflared tunnel create "$TUNNEL_NAME"
if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Falló la creación del túnel. Revisa si el nombre está en conflicto.${NC}"
    exit 1
fi

# 4. Route DNS (Force)
DOMAIN="sentinel.ihtechlabs.com"
echo "Enrutando DNS ($DOMAIN)..."
# Force route creation (-f might not be needed if tunnel is new, but safety first)
cloudflared tunnel route dns -f "$TUNNEL_NAME" "$DOMAIN"

if [ $? -ne 0 ]; then
   echo -e "${RED}❌ Falló la ruta DNS.${NC}"
fi

# 5. Service Configuration
echo "Configurando servicio..."
sudo mkdir -p /etc/cloudflared
sudo cp "$HOME/.cloudflared/cert.pem" /etc/cloudflared/
# Move the NEWLY created credential JSON
sudo cp "$HOME/.cloudflared"/*.json /etc/cloudflared/

# Get UUID (The newly created JSON in ~/.cloudflared)
# We find the specific JSON for this tunnel we just created.
# cloudflared tunnel create generates a file UUID.json.
# We can find it by looking for the most recent JSON file in .cloudflared
CRED_FILE=$(ls -t "$HOME/.cloudflared/"*.json | head -n 1)
if [ -z "$CRED_FILE" ]; then
    echo -e "${RED}❌ No se encontró archivo de credenciales JSON.${NC}"
    exit 1
fi
UUID=$(basename "$CRED_FILE" .json)

echo "Generando config.yml para Tunnel ID: $UUID"
sudo tee /etc/cloudflared/config.yml > /dev/null <<EOF
tunnel: $UUID
credentials-file: /etc/cloudflared/$UUID.json
ingress:
  - hostname: $DOMAIN
    service: http://localhost:3000
  - service: http_status:404
EOF

# 6. Install Service
echo "Instalando servicio..."
sudo cloudflared service install
sudo systemctl daemon-reload
sudo systemctl enable cloudflared
sudo systemctl restart cloudflared

echo -e "${GREEN}✅ Cloudflare recreado y servicio corriendo.${NC}"

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



# KIOSK AUTOSTART CONFIGURATION
echo "Configuring Kiosk Autostart..."
AUTOSTART_DIR="/home/develop/.config/autostart"
PROJECT_DIR="/home/develop/sentinel_simplified_app"
mkdir -p "$AUTOSTART_DIR"

cat > "$AUTOSTART_DIR/sentinel.desktop" <<EOL
[Desktop Entry]
Type=Application
Name=Sentinel Kiosk
Exec=$PROJECT_DIR/start_kiosk.sh
X-GNOME-Autostart-enabled=true
EOL

chmod +x "$AUTOSTART_DIR/sentinel.desktop"
echo -e "${GREEN}✅ Kiosk autostart configured.${NC}"

echo "Server Setup Complete."

#!/bin/bash

# Sentinel App Installer for Raspberry Pi
# Run this script on the RPi to setup the environment

echo "Checking dependencies..."

# Update System
sudo apt-get update

# Install System Dependencies (Chromium, Fonts, Utils)
echo "Installing system dependencies..."
sudo apt-get install -y chromium-browser fontconfig fonts-liberation x11-xserver-utils

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

# Kiosk Mode Setup
# This assumes we are on the RPi Desktop (Pixel/LXDE)
echo "Configuring Chromium Kiosk Mode..."

# Make start script executable
chmod +x $(pwd)/start.sh

mkdir -p ~/.config/autostart
cat <<EOF > ~/.config/autostart/kiosk.desktop
[Desktop Entry]
Type=Application
Name=Sentinel Kiosk
Exec=$(pwd)/start.sh
X-GNOME-Autostart-enabled=true
EOF

echo "Installation Complete! Rebooting in 5 seconds..."
# sleep 5
# sudo reboot

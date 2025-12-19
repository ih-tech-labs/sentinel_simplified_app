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

# Create Project Directory if it doesn't exist
# We assume the script is in the project root or we are moving it there.
# For this script, let's assume we are INSIDE the project folder already (e.g. pulled from git or copied)
# So we just install dependencies.

echo "Installing project dependencies..."
npm install

echo "Setting up autostart..."
# We can use PM2 or a Systemd service. PM2 is easier for Node.
if ! command -v pm2 &> /dev/null
then
    sudo npm install -g pm2
    pm2 startup
fi

# Start the server
pm2 start src/server.js --name sentinel-server
pm2 save

echo "Server Setup Complete."

# Kiosk Mode Setup
# This assumes we are on the RPi Desktop (Pixel/LXDE)
echo "Configuring Chromium Kiosk Mode..."

mkdir -p ~/.config/autostart
cat <<EOF > ~/.config/autostart/kiosk.desktop
[Desktop Entry]
Type=Application
Name=Sentinel Kiosk
Exec=/usr/bin/chromium-browser --noerrdialogs --disable-infobars --kiosk http://localhost:3000/kiosk/index.html
X-GNOME-Autostart-enabled=true
EOF

echo "Installation Complete! Rebooting in 5 seconds..."
# sleep 5
# sudo reboot

#!/bin/bash
echo "Installing Cloudflared..."

# Detect Architecture
ARCH=$(dpkg --print-architecture)
if [ "$ARCH" = "arm64" ]; then
    URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb"
elif [ "$ARCH" = "armhf" ]; then
    URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-armhf.deb"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

echo "Downloading for $ARCH..."
curl -L --output cloudflared.deb $URL

echo "Installing..."
sudo dpkg -i cloudflared.deb

echo ""
echo "========================================="
echo "INSTALACION COMPLETA"
echo "Para autenticar, ejecuta: cloudflared tunnel login"
echo "========================================="

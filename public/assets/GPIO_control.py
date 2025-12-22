#!/usr/bin/env python3
"""
GPIO Control - Comunicación con Arduino para control de dispositivos
Soporta: LEDs RGB/W, Sirena, Luz de Emergencia
"""

import sys
import time
from serial import Serial
from serial.tools.list_ports import comports

serialPort = None

def send_frame(frame):
    """
    Function to send a frame to the Arduino
    Frame format: "R,G,B,W,WW,EFFECT,-1,-1\n"
    """
    global serialPort
    if not serialPort:
        serialPort = init_com()

    if not frame.endswith('\n'):
        frame += '\n'
    
    serialPort.write(frame.encode())
    print(f"[Arduino] Frame sent: {frame.strip()}")

def init_com():
    """
    Function to find a connected Arduino and open a serial port
    Returns: Serial port object
    Raises: Exception if no Arduino found
    """
    portList = list(comports())

    for p in portList:
        if is_acm(p) or is_usb(p):  # ACM for Linux, COM for Windows
            print(f"[Arduino] Found Arduino on {p.device}")
            serialPort = Serial(p.device, 9600, timeout=1)
            time.sleep(2)  # Wait for Arduino to finish restarting
            print(f"[Arduino] Connected successfully")
            return serialPort

    raise Exception("No Arduino found. Please check connection.")

def is_acm(port):
    """Check if port is ACM (Linux)"""
    return "ACM" in port.description and "ACM" in port.device

def is_usb(port):
    """Check if port is USB (Windows/Mac)"""
    return "USB" in port.description or "USB" in str(port.device)

def validate_input(msg):
    """
    Validate that the message has the correct format
    Expected format: "R,G,B,W,WW,EFFECT,ARG1,ARG2"
    """
    parts = msg.strip().split(",")
    msg_length = len(parts)

    if msg_length != 8:
        error_msg = (
            f"Invalid message format. Expected 8 parameters, got {msg_length}.\n"
            f"Format: R,G,B,W,WW,EFFECT,ARG1,ARG2\n"
            f"Message: {msg}"
        )
        raise ValueError(error_msg)
    
    # Validate that all values are numeric
    try:
        [int(x) for x in parts]
    except ValueError:
        raise ValueError(f"All parameters must be numeric. Message: {msg}")

def close_connection():
    """Close the serial connection"""
    global serialPort
    if serialPort and serialPort.is_open:
        serialPort.close()
        print("[Arduino] Connection closed")

# --- Predefined frames for common operations ---
FRAMES = {
    # LEDs
    "led_white": "0,0,0,255,0,0,0,0",
    "led_red": "255,0,0,0,0,0,0,0",
    "led_green": "0,255,0,0,0,0,0,0",
    "led_yellow": "255,255,0,0,0,0,0,0",
    "led_blue": "0,0,255,0,0,0,0,0",
    "led_off": "0,0,0,0,0,0,0,0",
    
    # Siren (red blinking)
    "siren_on": "255,0,0,0,0,1,0,0",
    "siren_off": "0,0,0,0,0,0,0,0",
    
    # Emergency light (yellow/white blinking)
    "emergency_on": "255,255,0,255,0,2,0,0",
    "emergency_off": "0,0,0,0,0,0,0,0",
}

def send_predefined(command):
    """
    Send a predefined frame
    Args:
        command: One of the keys in FRAMES dict
    """
    if command not in FRAMES:
        available = ", ".join(FRAMES.keys())
        raise ValueError(f"Unknown command '{command}'. Available: {available}")
    
    frame = FRAMES[command]
    send_frame(frame)

# --- Main execution for command line usage ---
if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python3 GPIO_control.py <frame>")
        print("  python3 GPIO_control.py --predefined <command>")
        print("\nFrame format: R,G,B,W,WW,EFFECT,ARG1,ARG2")
        print("\nPredefined commands:")
        for cmd in sorted(FRAMES.keys()):
            print(f"  - {cmd}")
        sys.exit(1)
    
    try:
        if sys.argv[1] == "--predefined":
            if len(sys.argv) < 3:
                print("Error: --predefined requires a command name")
                sys.exit(1)
            
            command = sys.argv[2]
            send_predefined(command)
        else:
            frame = sys.argv[1]
            validate_input(frame)
            send_frame(frame)
        
        print("✅ Command sent successfully")
        close_connection()
        
    except Exception as e:
        print(f"❌ Error: {e}")
        sys.exit(1)

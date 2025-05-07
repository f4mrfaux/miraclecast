#!/bin/bash
# MiracleCast Universal Launcher
# Provides an integrated launcher with all improvements to address limitations

# Import utility functions
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
. "$SCRIPT_DIR/res/miracle-utils.sh" || { 
  echo -e "${RED}Error: Could not load miracle-utils.sh${NC}"
  exit 1
}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}This script must be run as root${NC}"
  exit 1
fi

# Settings with defaults
INTERFACE=""
MODE="sink"      # sink or source
AUTO_SCAN=true
UIBC_ENABLED=false
FIX_HARDWARE=true
FIX_GREEN_SCREEN=false
RESOLUTION=""
FPS=30
BITRATE=8192
SESSION_MANAGED=true

# Help function
show_help() {
    echo -e "${BLUE}MiracleCast Universal Launcher${NC}"
    echo "This script provides an integrated solution to MiracleCast's limitations"
    echo
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  -i <interface>   Specify WiFi interface to use"
    echo "  -m <mode>        Set mode: sink (receive) or source (send) [default: sink]"
    echo "  -r <WxH>         Set resolution (e.g., 1280x720)"
    echo "  -f <fps>         Set frame rate for source mode [default: 30]"
    echo "  -b <bitrate>     Set bitrate for source mode in kbps [default: 8192]"
    echo "  -u               Enable UIBC (User Input Back Channel) support"
    echo "  -g               Apply fix for green screen issues"
    echo "  -n               No hardware fixes (skip hardware compatibility checks)"
    echo "  -s               No session management (completely stop network services)"
    echo "  -h               Show this help message"
    echo
    echo "Examples:"
    echo "  $0 -i wlan0                     # Run in sink mode on wlan0"
    echo "  $0 -i wlan0 -m source           # Run in source mode on wlan0"
    echo "  $0 -i wlan0 -u                  # Run with UIBC support"
    echo "  $0 -i wlan0 -m source -r 1280x720 -f 25   # Run source with custom settings"
    echo "  $0 -i wlan0 -g                  # Run with green screen fixes"
    echo
}

# Parse command-line arguments
while getopts "i:m:r:f:b:ugnsh" opt; do
    case $opt in
        i)
            INTERFACE="$OPTARG"
            ;;
        m)
            MODE=$(echo "$OPTARG" | tr '[:upper:]' '[:lower:]')
            if [[ "$MODE" != "sink" && "$MODE" != "source" ]]; then
                echo -e "${RED}Invalid mode: $OPTARG. Must be 'sink' or 'source'${NC}"
                exit 1
            fi
            ;;
        r)
            RESOLUTION="$OPTARG"
            if ! [[ $RESOLUTION =~ ^[0-9]+x[0-9]+$ ]]; then
                echo -e "${RED}Invalid resolution format. Must be WIDTHxHEIGHT (e.g., 1280x720)${NC}"
                exit 1
            fi
            ;;
        f)
            FPS="$OPTARG"
            if ! [[ $FPS =~ ^[0-9]+$ ]]; then
                echo -e "${RED}Invalid frame rate: $FPS. Must be a number.${NC}"
                exit 1
            elif [ "$FPS" -lt 10 ] || [ "$FPS" -gt 60 ]; then
                echo -e "${RED}Invalid frame rate: $FPS. Must be between 10-60 fps.${NC}"
                exit 1
            fi
            ;;
        b)
            BITRATE="$OPTARG"
            if ! [[ $BITRATE =~ ^[0-9]+$ ]]; then
                echo -e "${RED}Invalid bitrate: $BITRATE. Must be a number.${NC}"
                exit 1
            elif [ "$BITRATE" -lt 1000 ] || [ "$BITRATE" -gt 20000 ]; then
                echo -e "${RED}Invalid bitrate: $BITRATE. Must be between 1000-20000 kbps.${NC}"
                exit 1
            fi
            ;;
        u)
            UIBC_ENABLED=true
            ;;
        g)
            FIX_GREEN_SCREEN=true
            ;;
        n)
            FIX_HARDWARE=false
            ;;
        s)
            SESSION_MANAGED=false
            ;;
        h)
            show_help
            exit 0
            ;;
        \?)
            echo -e "${RED}Invalid option: -$OPTARG${NC}"
            show_help
            exit 1
            ;;
        :)
            echo -e "${RED}Option -$OPTARG requires an argument.${NC}"
            show_help
            exit 1
            ;;
    esac
done

# If no interface is specified, show available interfaces and prompt
if [ -z "$INTERFACE" ]; then
    echo -e "${BLUE}Available wireless interfaces:${NC}"
    WIFI_NAMES="$(find_wireless_network_interfaces)"
    WIFI_COUNT=$(echo "$WIFI_NAMES" | wc -l)
    
    if [ "$WIFI_COUNT" -eq 0 ]; then
        echo -e "${RED}No wireless interfaces found.${NC}"
        exit 1
    fi
    
    # Display available interfaces with numbers
    i=1
    for iface in $WIFI_NAMES; do
        echo "$i) $iface"
        ((i++))
    done
    
    echo
    read -p "Select interface number [1-$WIFI_COUNT]: " SELECTION
    
    if ! [[ $SELECTION =~ ^[0-9]+$ ]] || [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt "$WIFI_COUNT" ]; then
        echo -e "${RED}Invalid selection.${NC}"
        exit 1
    fi
    
    # Get the selected interface name
    INTERFACE=$(echo "$WIFI_NAMES" | sed -n "${SELECTION}p")
fi

echo -e "${BLUE}Using interface:${NC} $INTERFACE"
echo -e "${BLUE}Mode:${NC} $MODE"

# Apply hardware fixes if enabled
if [ "$FIX_HARDWARE" = true ]; then
    echo -e "${BLUE}Checking hardware compatibility...${NC}"
    # Check P2P capabilities
    if ! search_p2p_capabilities "$INTERFACE" &>/dev/null; then
        echo -e "${RED}Interface $INTERFACE does not support P2P/WiFi Direct!${NC}"
        echo "Please use a different interface with P2P support."
        exit 1
    fi
    
    # Run basic hardware fixes
    if [ -f "$SCRIPT_DIR/res/hardware-compatibility-fixer.sh" ]; then
        # Check if executable
        if [ ! -x "$SCRIPT_DIR/res/hardware-compatibility-fixer.sh" ]; then
            chmod +x "$SCRIPT_DIR/res/hardware-compatibility-fixer.sh" || {
                echo -e "${RED}Could not make hardware compatibility fixer executable${NC}"
                exit 1
            }
        fi
        "$SCRIPT_DIR/res/hardware-compatibility-fixer.sh" || {
            echo -e "${YELLOW}Hardware compatibility check failed, but continuing${NC}"
        }
    else
        echo -e "${YELLOW}Hardware compatibility fixer not found at $SCRIPT_DIR/res/hardware-compatibility-fixer.sh${NC}"
    fi
fi

# Apply green screen fix if requested
if [ "$FIX_GREEN_SCREEN" = true ]; then
    echo -e "${BLUE}Applying green screen fix...${NC}"
    export GST_VIDEO_CONVERT_USE_ARGB=1
    echo "Set GST_VIDEO_CONVERT_USE_ARGB=1"
fi

# Prepare network interface using session manager or traditional method
if [ "$SESSION_MANAGED" = true ]; then
    echo -e "${BLUE}Using session-based network management${NC}"
    if [ -f "$SCRIPT_DIR/res/network-session-manager.sh" ]; then
        # Check if executable
        if [ ! -x "$SCRIPT_DIR/res/network-session-manager.sh" ]; then
            chmod +x "$SCRIPT_DIR/res/network-session-manager.sh" || {
                echo -e "${RED}Could not make network session manager executable${NC}"
                kill_network_manager
                return
            }
        fi
        
        if ! "$SCRIPT_DIR/res/network-session-manager.sh" prepare "$INTERFACE"; then
            echo -e "${YELLOW}Network session manager failed, falling back to traditional method${NC}"
            kill_network_manager
        fi
    else
        echo -e "${YELLOW}Network session manager not found at $SCRIPT_DIR/res/network-session-manager.sh, falling back to traditional method${NC}"
        kill_network_manager
    fi
else
    echo -e "${BLUE}Using traditional network management (full stop)${NC}"
    kill_network_manager
fi

# Function to run when script is terminated
cleanup() {
    echo -e "\n${BLUE}Cleaning up...${NC}"
    
    # Stop any running services
    echo "Stopping MiracleCast services..."
    killall miracle-wifid 2>/dev/null
    killall miracle-sinkctl 2>/dev/null
    killall miracle-wifictl 2>/dev/null
    
    # Stop UIBC if running
    killall miracle-uibcctl 2>/dev/null
    killall enhanced-uibc-viewer 2>/dev/null
    
    # Stop streaming if in source mode
    if [ "$MODE" = "source" ]; then
        echo "Stopping stream if running..."
        echo "stream-stop" | miracle-wifictl >/dev/null 2>&1
    fi
    
    # Restore network if using session management
    if [ "$SESSION_MANAGED" = true ] && [ -f "$SCRIPT_DIR/res/network-session-manager.sh" ]; then
        # Check if executable
        if [ ! -x "$SCRIPT_DIR/res/network-session-manager.sh" ]; then
            chmod +x "$SCRIPT_DIR/res/network-session-manager.sh" || {
                echo -e "${RED}Could not make network session manager executable${NC}"
                echo "Falling back to traditional network restoration"
                start_network_manager
                return
            }
        fi
        
        if ! "$SCRIPT_DIR/res/network-session-manager.sh" restore; then
            echo -e "${YELLOW}Network session manager restore failed, using traditional method${NC}"
            start_network_manager
        fi
    else
        # Traditional network restoration
        echo "Restoring network services..."
        start_network_manager
    fi
    
    echo -e "${GREEN}Cleanup complete.${NC}"
}

# Set up cleanup on exit
trap cleanup EXIT INT TERM

# Start MiracleCast WiFi daemon
echo -e "${BLUE}Starting MiracleCast WiFi daemon...${NC}"
miracle-wifid -i "$INTERFACE" &
WIFID_PID=$!
sleep 2

# Run in appropriate mode
if [ "$MODE" = "sink" ]; then
    # SINK MODE (RECEIVE)
    echo -e "${BLUE}Starting Sink Mode (Receive)...${NC}"
    
    # Build sinkctl command
    SINKCTL_CMD="miracle-sinkctl"
    if [ "$UIBC_ENABLED" = true ]; then
        SINKCTL_CMD="$SINKCTL_CMD --uibc"
        echo "UIBC support enabled"
    fi
    if [ "$FIX_GREEN_SCREEN" = true ]; then
        echo "Using improved GStreamer player with green screen fix"
        cp ./res/miracle-gst-improved /tmp/miracle-gst
        chmod +x /tmp/miracle-gst
        export PATH="/tmp:$PATH"
    fi
    
    # Run MiracleCast in sink mode
    echo "Running: $SINKCTL_CMD"
    
    # Start sink control
    $SINKCTL_CMD
    
elif [ "$MODE" = "source" ]; then
    # SOURCE MODE (SEND)
    echo -e "${BLUE}Starting Source Mode (Send)...${NC}"
    
    # Start WiFi control for scanning and connection
    miracle-wifictl <<EOF
select $INTERFACE
set-managed yes
p2p-scan
list
EOF
    
    echo -e "\n${YELLOW}Please connect to a peer device using:${NC}"
    echo -e "  ${GREEN}connect PEER_ID${NC}"
    echo -e "  ${GREEN}stream-start PEER_ID ${RESOLUTION:+res=$RESOLUTION }fps=$FPS bitrate=$BITRATE${NC}"
    echo -e "  ${GREEN}stream-stop${NC}"
    echo -e "  ${GREEN}exit${NC} to quit"
    
    # Interactive mode for user
    miracle-wifictl
fi

# Script will call cleanup on exit
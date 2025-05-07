#!/bin/bash
# Network Session Manager for MiracleCast
# Manages network services for MiracleCast while minimizing system disruption

# Get absolute script directory for reliable paths
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# Source utility functions
. "$SCRIPT_DIR/miracle-utils.sh" || {
    echo -e "${RED}Failed to load miracle-utils.sh${NC}"
    exit 1
}

# Script path already defined above

# Generate a random session ID for security
SESSION_ID="$(dd if=/dev/urandom bs=1 count=8 2>/dev/null | hexdump -e '"%02x"')"
if [ -z "$SESSION_ID" ]; then
    # Fallback if dd or hexdump fails
    SESSION_ID="$$-$(date +%s)"
fi

# Session file to track what we've modified
SESSION_FILE="/tmp/miraclecast-session.${SESSION_ID}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root${NC}"
  exit 1
fi

# Create secure session file with restricted permissions
install -m 600 /dev/null "$SESSION_FILE" || {
    echo -e "${RED}Failed to create secure session file${NC}"
    exit 1
}

# Function to safely stop NetworkManager without disrupting all connections
safe_stop_network_manager() {
    local interface="$1"
    echo -e "${BLUE}Safely stopping NetworkManager for interface $interface...${NC}"
    
    # Check if interface is managed by NetworkManager
    if nmcli device show "$interface" &>/dev/null; then
        # Get current connection details before disconnecting
        local SSID=$(nmcli -t -f active,ssid dev wifi | grep ^yes | cut -d: -f2)
        local PASSWORD=$(nmcli -s -t -f 802-11-wireless-security.psk connection show "$SSID" 2>/dev/null | cut -d: -f2)
        
        # Store connection information for later restoration
        if [ -n "$SSID" ]; then
            echo "INTERFACE=$interface" >> "$SESSION_FILE"
            echo "SSID=$SSID" >> "$SESSION_FILE"
            if [ -n "$PASSWORD" ]; then
                echo "PASSWORD=$PASSWORD" >> "$SESSION_FILE"
            fi
            echo "NM_WAS_ACTIVE=1" >> "$SESSION_FILE"
        fi
        
        # Set device unmanaged in NetworkManager
        nmcli device set "$interface" managed no
        echo -e "${GREEN}Interface $interface set to unmanaged in NetworkManager${NC}"
    else
        echo "Interface $interface is not managed by NetworkManager"
    fi
}

# Function to safely stop wpa_supplicant for a specific interface
safe_stop_wpa_supplicant() {
    local interface="$1"
    
    # Validate interface name to prevent command injection
    if ! [[ "$interface" =~ ^[a-zA-Z0-9_]+$ ]]; then
        echo -e "${RED}Invalid interface name format: $interface${NC}"
        return 1
    fi
    
    echo -e "${BLUE}Safely stopping wpa_supplicant for interface $interface...${NC}"
    
    # Find wpa_supplicant process for this interface
    local pid=$(pgrep -f "wpa_supplicant.*-i\s*$interface")
    
    if [ -n "$pid" ]; then
        echo "WPA_PID_$interface=$pid" >> "$SESSION_FILE"
        echo "WPA_WAS_ACTIVE_$interface=1" >> "$SESSION_FILE"
        
        # Capture wpa_supplicant config if possible
        local config_file=$(ps -p "$pid" -o cmd= | grep -o -- "-c\s*[^ ]*" | cut -d' ' -f2)
        if [ -n "$config_file" ] && [ -f "$config_file" ]; then
            echo "WPA_CONFIG_$interface=$config_file" >> "$SESSION_FILE"
        fi
        
        # Kill wpa_supplicant for this interface only
        if ! kill "$pid"; then
            echo -e "${YELLOW}Failed to stop wpa_supplicant process $pid, trying SIGKILL${NC}"
            kill -9 "$pid" || echo -e "${RED}Failed to forcibly stop wpa_supplicant${NC}"
        fi
        
        # Verify process was stopped
        if ! ps -p "$pid" > /dev/null; then
            echo -e "${GREEN}Stopped wpa_supplicant for interface $interface${NC}"
            return 0
        else
            echo -e "${RED}Failed to stop wpa_supplicant for interface $interface${NC}"
            return 1
        fi
    else
        echo "No wpa_supplicant running for interface $interface"
        return 0
    fi
}

# Function to prepare interface for MiracleCast
prepare_interface() {
    local interface="$1"
    
    echo -e "${BLUE}Preparing interface $interface for MiracleCast...${NC}"
    
    # First check if P2P is supported
    if ! search_p2p_capabilities "$interface" &>/dev/null; then
        echo -e "${RED}Interface $interface does not support P2P. Cannot continue.${NC}"
        exit 1
    fi
    
    # Save current IP configuration
    local IP_ADDR=$(ip addr show dev "$interface" | grep -w inet | awk '{print $2}')
    if [ -n "$IP_ADDR" ]; then
        echo "INTERFACE_IP_$interface=$IP_ADDR" >> "$SESSION_FILE"
    fi
    
    # Safe stop of services
    safe_stop_network_manager "$interface"
    safe_stop_wpa_supplicant "$interface"
    
    # Bring interface up for P2P
    ip link set "$interface" up
    
    echo -e "${GREEN}Interface $interface is ready for MiracleCast${NC}"
}

# Function to restore system after MiracleCast
restore_system() {
    echo -e "${BLUE}Restoring network services...${NC}"
    
    # Load session info
    if [ ! -f "$SESSION_FILE" ]; then
        echo -e "${RED}Session file not found. Cannot restore properly.${NC}"
        return 1
    fi
    
    # Source session file to get variables
    source "$SESSION_FILE"
    
    # Get interface from session file
    if [ -n "$INTERFACE" ]; then
        # Re-enable NetworkManager management of interface if it was active
        if [ "$NM_WAS_ACTIVE" = "1" ]; then
            echo "Re-enabling NetworkManager for $INTERFACE"
            nmcli device set "$INTERFACE" managed yes
            
            # Reconnect to previous network if we have SSID
            if [ -n "$SSID" ]; then
                echo "Reconnecting to $SSID"
                if [ -n "$PASSWORD" ]; then
                    nmcli device wifi connect "$SSID" password "$PASSWORD" ifname "$INTERFACE"
                else
                    nmcli device wifi connect "$SSID" ifname "$INTERFACE"
                fi
            fi
        fi
        
        # Restore wpa_supplicant if it was active for this interface
        local wpa_was_active_var="WPA_WAS_ACTIVE_$INTERFACE"
        if [ "${!wpa_was_active_var}" = "1" ]; then
            echo "Restarting wpa_supplicant for $INTERFACE"
            
            local wpa_config_var="WPA_CONFIG_$INTERFACE"
            if [ -n "${!wpa_config_var}" ] && [ -f "${!wpa_config_var}" ]; then
                wpa_supplicant -B -i "$INTERFACE" -c "${!wpa_config_var}"
            else
                # Generic restart using default config
                wpa_supplicant -B -i "$INTERFACE" -c /etc/wpa_supplicant/wpa_supplicant.conf
            fi
        fi
        
        # Restore IP address if we had one
        local ip_addr_var="INTERFACE_IP_$INTERFACE"
        if [ -n "${!ip_addr_var}" ]; then
            echo "Restoring IP address ${!ip_addr_var} to $INTERFACE"
            ip addr add "${!ip_addr_var}" dev "$INTERFACE"
        fi
    fi
    
    echo -e "${GREEN}Network services restored${NC}"
    
    # Securely clean up session file
    if command -v shred >/dev/null 2>&1; then
        shred -u "$SESSION_FILE" || rm -f "$SESSION_FILE"
    else
        rm -f "$SESSION_FILE"
    fi
}

# Function to handle interruptions and cleanup
handle_interrupt() {
    echo -e "\n${YELLOW}Interrupted, restoring network services...${NC}"
    restore_system
    exit 130
}

# Register trap for SIGINT
trap handle_interrupt SIGINT SIGTERM

# Command line handling
if [ $# -lt 1 ]; then
    echo "Usage: $0 [prepare|restore] [interface]"
    echo "  prepare [interface]: Prepare specified interface for MiracleCast"
    echo "  restore: Restore network services to previous state"
    exit 1
fi

case "$1" in
    prepare)
        if [ -z "$2" ]; then
            echo -e "${RED}Error: Interface name required${NC}"
            echo "Usage: $0 prepare [interface]"
            exit 1
        fi
        prepare_interface "$2"
        ;;
    restore)
        restore_system
        ;;
    *)
        echo "Unknown command: $1"
        echo "Usage: $0 [prepare|restore] [interface]"
        exit 1
        ;;
esac

exit 0
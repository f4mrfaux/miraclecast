#!/bin/bash
# MiracleCast Hardware Compatibility Fixer
# Identifies and attempts to fix common hardware compatibility issues

. ./miracle-utils.sh

# Colors for better output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}MiracleCast Hardware Compatibility Fixer${NC}"
echo "This script diagnoses common hardware issues and provides solutions."
echo

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root to perform all checks.${NC}"
  exit 1
fi

# Step 1: Check for compatible wireless interfaces
echo -e "${BLUE}Step 1: Checking for compatible wireless interfaces...${NC}"
WIFI_NAMES="$(find_wireless_network_interfaces)"
if [ -z "$WIFI_NAMES" ]; then
  echo -e "${RED}No wireless interfaces found.${NC}"
  echo "MiracleCast requires a wireless network interface."
  exit 1
else
  echo -e "${GREEN}Found wireless interfaces:${NC}"
  for iface in $WIFI_NAMES; do
    echo "  - $iface"
  done
fi

# Step 2: Check each interface for P2P support
echo -e "\n${BLUE}Step 2: Checking interfaces for P2P (WiFi Direct) support...${NC}"
P2P_SUPPORTED=false
for iface in $WIFI_NAMES; do
  echo -n "  - Checking $iface: "
  PHY_DEVICE=$(find_physical_for_network_interface $iface)
  
  if [ -z "$PHY_DEVICE" ]; then
    echo -e "${RED}Cannot find physical device.${NC}"
    continue
  fi
  
  if iw phy $PHY_DEVICE info | grep -Pzo "(?s)Supported interface modes.*Supported commands" | grep "P2P" &> /dev/null; then
    echo -e "${GREEN}Supports P2P${NC}"
    P2P_SUPPORTED=true
    # Get driver info for reference
    DRIVER=$(readlink -f /sys/class/net/$iface/device/driver 2>/dev/null | xargs basename 2>/dev/null || echo "unknown")
    echo "    Driver: $DRIVER"
  else
    echo -e "${RED}Does NOT support P2P${NC}"
    # Get driver info for reference
    DRIVER=$(readlink -f /sys/class/net/$iface/device/driver 2>/dev/null | xargs basename 2>/dev/null || echo "unknown")
    echo "    Driver: $DRIVER"
  fi
done

if ! $P2P_SUPPORTED; then
  echo -e "${RED}No interfaces with P2P support found.${NC}"
  echo "MiracleCast requires a wireless interface with P2P (WiFi Direct) support."
  echo "Known working drivers: ath9k, ath10k, iwlwifi, rtl8192cu (with patches)"
  echo
  echo "For unsupported drivers, you might try:"
  echo "1. Update your kernel to the latest version"
  echo "2. If using a USB adapter, try a different one with known P2P support"
  echo "3. Check if your WiFi driver has optional P2P support that needs enabling"
else
  echo -e "${GREEN}Found at least one interface with P2P support!${NC}"
fi

# Step 3: Check for GStreamer and dependencies
echo -e "\n${BLUE}Step 3: Checking for video playback dependencies...${NC}"

# Check GStreamer
echo -n "  - GStreamer: "
if command -v gst-launch-1.0 &> /dev/null; then
    echo -e "${GREEN}Installed${NC}"
    
    # Check H.264 support for green screen issues
    echo -n "  - H.264 decoding: "
    if gst-inspect-1.0 avdec_h264 &> /dev/null; then
        echo -e "${GREEN}Supported${NC}"
    else
        echo -e "${RED}Not found${NC}"
        echo "    Missing H.264 decoder could cause green screen issues"
        echo "    Install gstreamer1.0-libav or gstreamer1.0-plugins-bad"
    fi
    
    # Check video conversion plugins for colorspace issues
    echo -n "  - Video conversion: "
    if gst-inspect-1.0 videoconvert &> /dev/null; then
        echo -e "${GREEN}Supported${NC}"
    else
        echo -e "${RED}Not found${NC}"
        echo "    Missing videoconvert plugin could cause color issues"
        echo "    Install gstreamer1.0-plugins-base"
    fi
else
    echo -e "${RED}Not installed${NC}"
    echo "    GStreamer is required for video playback"
    echo "    Install gstreamer1.0-tools and plugins packages"
fi

# Step 4: Check for common dependency services
echo -e "\n${BLUE}Step 4: Checking system services...${NC}"

echo -n "  - SystemD: "
if command -v systemctl &> /dev/null; then
    VERSION=$(systemctl --version | head -n 1 | awk '{print $2}')
    if [ "$VERSION" -ge 221 ]; then
        echo -e "${GREEN}Version $VERSION (Supported)${NC}"
    else
        echo -e "${YELLOW}Version $VERSION (May need compilation with --enable-kdbus)${NC}"
    fi
else
    echo -e "${RED}Not found${NC}"
    echo "    SystemD is required for MiracleCast"
fi

echo -n "  - NetworkManager: "
if systemctl status NetworkManager &> /dev/null; then
    echo -e "${GREEN}Running${NC} (will need to be stopped during MiracleCast operation)"
else
    echo -e "${YELLOW}Not running${NC}"
fi

echo -n "  - wpa_supplicant: "
if systemctl status wpa_supplicant &> /dev/null || pgrep wpa_supplicant &> /dev/null; then
    echo -e "${GREEN}Running${NC} (will need to be stopped during MiracleCast operation)"
else
    echo -e "${YELLOW}Not running${NC}"
fi

# Step 5: Check for useful optional tools
echo -e "\n${BLUE}Step 5: Checking for optional tools...${NC}"

echo -n "  - VLC: "
if command -v vlc &> /dev/null || command -v cvlc &> /dev/null; then
    echo -e "${GREEN}Installed${NC} (useful alternative streaming backend)"
else
    echo -e "${YELLOW}Not installed${NC} (optional)"
fi

# Create a fix script for known issues
echo -e "\n${BLUE}Creating fix script for common issues...${NC}"

cat > fix-common-issues.sh << 'EOF'
#!/bin/bash
# MiracleCast Common Issues Fixer

# Fix for green screen issues with GStreamer
fix_green_screen() {
    # Add environment variable to fix color format issues
    echo 'export GST_VIDEO_CONVERT_USE_ARGB=1' > /etc/profile.d/gst-miraclecast-fix.sh
    chmod +x /etc/profile.d/gst-miraclecast-fix.sh
    echo "Added GST_VIDEO_CONVERT_USE_ARGB=1 to fix green screen issues"
    echo "Please log out and log back in for the changes to take effect"
}

# Fix for audio synchronization issues
fix_audio_sync() {
    # Modify miracle-gst to include a higher latency value
    sed -i 's/rtpjitterbuffer latency=100/rtpjitterbuffer latency=500/g' /usr/bin/miracle-gst
    echo "Increased RTP jitter buffer latency to improve audio sync"
}

# Fix for P2P connection issues
fix_p2p_connection() {
    echo "Applying P2P connection fixes..."
    # Create wpa_supplicant config with extended timeouts
    cat > /etc/miraclecast/p2p-extended.conf << 'EOC'
ctrl_interface=/var/run/wpa_supplicant
p2p_go_ht40=1
p2p_go_max_inactivity=60
p2p_search_delay=10
driver_param=p2p_device=1
EOC
    echo "Created extended P2P configuration at /etc/miraclecast/p2p-extended.conf"
    echo "Use it with: sudo wpa_supplicant -Dnl80211 -i<interface> -c/etc/miraclecast/p2p-extended.conf"
}

# Main menu
echo "MiracleCast Common Issues Fixer"
echo "Please select an issue to fix:"
echo "1. Green screen problems (GStreamer color format issue)"
echo "2. Audio/video sync problems"
echo "3. P2P connection timeouts or failures"
echo "4. All of the above"
echo "5. Exit"

read -p "Select option [1-5]: " option

case $option in
    1) fix_green_screen ;;
    2) fix_audio_sync ;;
    3) fix_p2p_connection ;;
    4) 
        fix_green_screen
        fix_audio_sync
        fix_p2p_connection
        ;;
    5) echo "Exiting without changes." ;;
    *) echo "Invalid option." ;;
esac
EOF

chmod +x fix-common-issues.sh
echo -e "${GREEN}Created fix-common-issues.sh script to address common problems${NC}"

# Step 6: Summary and recommendations
echo -e "\n${BLUE}Summary and Recommendations:${NC}"

if $P2P_SUPPORTED; then
    echo -e "1. ${GREEN}Your system has WiFi interfaces with P2P support${NC}"
else
    echo -e "1. ${RED}No WiFi interfaces with P2P support detected${NC}"
    echo "   - Consider updating your WiFi driver or kernel"
    echo "   - Try a different WiFi adapter with known P2P support"
fi

echo "2. For green screen issues:"
echo "   - Run the fix-common-issues.sh script option 1"
echo "   - Set environment variable: GST_VIDEO_CONVERT_USE_ARGB=1"
echo "   - Install full GStreamer plugin packages"

echo "3. For connection issues:"
echo "   - Ensure NetworkManager and wpa_supplicant are properly stopped"
echo "   - Try using wpa_supplicant directly with modified timeouts"
echo "   - Run fix-common-issues.sh option 3"

echo -e "\n${GREEN}Run ./fix-common-issues.sh to apply fixes${NC}"
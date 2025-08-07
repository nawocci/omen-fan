#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root${NC}"
   echo "Please run with: sudo ./uninstall.sh"
   exit 1
fi

echo -e "${YELLOW}HP Omen Fan Control Uninstallation${NC}"
echo "=================================="

echo -e "${YELLOW}Stopping and disabling service...${NC}"
systemctl stop omen-fand 2>/dev/null || true
systemctl disable omen-fand 2>/dev/null || true

echo -e "${YELLOW}Removing systemd service...${NC}"
rm -f /etc/systemd/system/omen-fand.service
systemctl daemon-reload

echo -e "${YELLOW}Removing executables...${NC}"
rm -f /usr/local/bin/omen-fan
rm -f /usr/local/bin/omen-fand
rm -f /tmp/omen-fand.PID

echo -e "${YELLOW}Do you want to remove configuration and log files? (y/N)${NC}"
read -r response
if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    rm -rf /etc/omen-fan
    rm -rf /var/log/omen-fan
    rm -f /etc/logrotate.d/omen-fan
    echo -e "${GREEN}Configuration and logs removed.${NC}"
else
    echo -e "${GREEN}Configuration and logs preserved.${NC}"
fi

echo -e "${YELLOW}Do you want to remove ec_sys module configuration? (y/N)${NC}"
read -r response
if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    rm -f /etc/modules-load.d/ec_sys.conf
    rm -f /etc/modprobe.d/ec_sys.conf
    echo -e "${GREEN}ec_sys module configuration removed.${NC}"
    echo -e "${YELLOW}Note: You may need to reboot to fully unload the module.${NC}"
else
    echo -e "${GREEN}ec_sys module configuration preserved.${NC}"
fi

echo -e "${GREEN}Uninstallation completed successfully!${NC}"

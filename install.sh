#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root${NC}"
   echo "Please run with: sudo ./install.sh"
   exit 1
fi

echo -e "${GREEN}HP Omen Fan Control Installation${NC}"
echo "================================="

echo -e "${YELLOW}Installing dependencies...${NC}"
if command -v apt-get &> /dev/null; then
    apt-get update
    apt-get install -y python3 python3-pip python3-click logrotate
    echo -e "${YELLOW}Installing Python dependencies...${NC}"
    pip3 install click-aliases
elif command -v yum &> /dev/null; then
    yum install -y python3 python3-pip logrotate
    echo -e "${YELLOW}Installing Python dependencies...${NC}"
    pip3 install click-aliases
elif command -v pacman &> /dev/null; then
    pacman -S --noconfirm python python-pip python-click logrotate
    echo -e "${YELLOW}Installing Python dependencies...${NC}"
    if ! pacman -S --noconfirm python-click-aliases 2>/dev/null; then
        echo -e "${YELLOW}python-click-aliases not available in pacman, using pip with --break-system-packages...${NC}"
        pip3 install click-aliases --break-system-packages
    fi
else
    echo -e "${RED}Error: Unsupported package manager. Please install python3, python3-pip, and python3-click manually.${NC}"
    exit 1
fi

echo -e "${YELLOW}Creating directories...${NC}"
mkdir -p /etc/omen-fan
mkdir -p /var/log/omen-fan
mkdir -p /usr/local/bin

echo -e "${YELLOW}Installing executables...${NC}"
cp omen-fan.py /usr/local/bin/omen-fan
cp omen-fand.py /usr/local/bin/omen-fand
chmod +x /usr/local/bin/omen-fan
chmod +x /usr/local/bin/omen-fand

echo -e "${YELLOW}Creating systemd service...${NC}"
cat > /etc/systemd/system/omen-fand.service << 'EOF'
[Unit]
Description=HP Omen Fan Control Daemon
After=multi-user.target
Wants=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/omen-fand
ExecStop=/bin/kill -TERM $MAINPID
Restart=always
RestartSec=5
User=root
PIDFile=/tmp/omen-fand.PID
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo -e "${YELLOW}Reloading systemd configuration...${NC}"
systemctl daemon-reload

echo -e "${YELLOW}Loading ec_sys module...${NC}"
if ! lsmod | grep -q ec_sys; then
    modprobe ec_sys write_support=1
fi

echo -e "${YELLOW}Making ec_sys module load persistent...${NC}"
mkdir -p /etc/modules-load.d
if ! grep -q "ec_sys" /etc/modules-load.d/ec_sys.conf 2>/dev/null; then
    echo "ec_sys" > /etc/modules-load.d/ec_sys.conf
fi

mkdir -p /etc/modprobe.d
if ! grep -q "options ec_sys write_support=1" /etc/modprobe.d/ec_sys.conf 2>/dev/null; then
    echo "options ec_sys write_support=1" > /etc/modprobe.d/ec_sys.conf
fi

echo -e "${YELLOW}Creating initial configuration...${NC}"
if ! python3 -c "import click, click_aliases" 2>/dev/null; then
    echo -e "${YELLOW}Python dependencies not fully available, attempting alternative installation...${NC}"
    pip3 install click-aliases --user 2>/dev/null || {
        echo -e "${YELLOW}Using pip with --break-system-packages as last resort...${NC}"
        pip3 install click-aliases --break-system-packages || {
            echo -e "${RED}Warning: Could not install click-aliases. You may need to install it manually.${NC}"
            echo -e "${RED}Try: pip3 install click-aliases --user${NC}"
        }
    }
fi

/usr/local/bin/omen-fan configure --view > /dev/null 2>&1 || {
    echo -e "${YELLOW}Note: Configuration test failed. Dependencies may need manual installation.${NC}"
}

echo -e "${YELLOW}Setting up log rotation...${NC}"
if command -v logrotate &> /dev/null; then
    mkdir -p /etc/logrotate.d
    cat > /etc/logrotate.d/omen-fan << 'EOF'
/var/log/omen-fan/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    copytruncate
}
EOF
    echo -e "${GREEN}Log rotation configured successfully${NC}"
else
    echo -e "${YELLOW}logrotate not found, skipping log rotation setup${NC}"
fi

echo -e "${GREEN}Installation completed successfully!${NC}"
echo ""
echo "Available commands:"
echo "  omen-fan --help              - Show help"
echo "  omen-fan info                - Show fan status"
echo "  omen-fan service start       - Start fan service"
echo "  omen-fan service stop        - Stop fan service"
echo "  omen-fan configure --view    - View configuration"
echo "  systemctl enable omen-fand   - Enable service at boot"
echo "  systemctl start omen-fand    - Start service now"
echo ""
echo -e "${YELLOW}Note: You may need to reboot for the ec_sys module to load properly.${NC}"
echo -e "${YELLOW}After reboot, run 'systemctl enable omen-fand' and 'systemctl start omen-fand'${NC}"

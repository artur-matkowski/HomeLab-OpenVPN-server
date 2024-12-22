#!/bin/bash
set -e
set -x

# Check if already in sysctl.conf
if grep -Fxq "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
  echo "IP forwarding already enabled in /etc/sysctl.conf"
else
  echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
fi

# Force reload sysctl settings
sudo sysctl -p /etc/sysctl.conf

echo "IP forwarding enabled on the host!"

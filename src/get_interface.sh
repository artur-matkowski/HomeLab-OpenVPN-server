#!/usr/bin/env bash
# get_interface.sh    – return the outgoing/interface name for the supplied IP

if [[ -z $1 ]]; then
  echo "usage: $0 <ip-address>"
  exit 1
fi

# “ip route get” asks the kernel which interface it would use to reach $1
# we then pull out the word after “dev”
ip route get "$1" 2>/dev/null |
  awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'

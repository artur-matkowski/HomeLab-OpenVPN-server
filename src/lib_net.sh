# lib_net.sh — IPv4 helpers shared by init_vpn.sh and generate_client.sh.
#
# Source it (do NOT execute):  . /usr/local/lib/lib_net.sh
#
# Pure bash, no external commands. Single source of truth for the address
# math behind static-IP assignment and the dynamic-pool split, so the two
# scripts can never disagree on what counts as a valid address (a drift here
# would silently hand out colliding tunnel IPs — see docs/architecture.md).
#
# All functions take/return dotted-quad IPv4 strings. The integer helpers use
# bash's 64-bit signed arithmetic, which comfortably holds a 32-bit address.

# ip2int <dotted-quad> -> prints the address as an unsigned 32-bit integer.
ip2int() {
    local IFS=. a b c d
    read -r a b c d <<< "$1"
    printf '%u\n' "$(( (a << 24) | (b << 16) | (c << 8) | d ))"
}

# valid_ipv4 <string> -> 0 if a well-formed dotted-quad with octets 0..255.
valid_ipv4() {
    local ip=$1 o
    [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    local IFS=.
    for o in $ip; do
        (( o >= 0 && o <= 255 )) || return 1
    done
    return 0
}

# ip_in_subnet <ip> <network> <netmask> -> 0 if ip belongs to network/netmask.
ip_in_subnet() {
    local ip net mask
    ip=$(ip2int "$1"); net=$(ip2int "$2"); mask=$(ip2int "$3")
    (( (ip & mask) == (net & mask) ))
}

# ip_in_range <ip> <start> <end> -> 0 if start <= ip <= end (inclusive).
ip_in_range() {
    local ip start end
    ip=$(ip2int "$1"); start=$(ip2int "$2"); end=$(ip2int "$3")
    (( ip >= start && ip <= end ))
}

# is_assignable_host <ip> <network> <netmask> -> 0 if ip is a usable host in
# the subnet: not the network address, not the broadcast address, and not the
# hub itself (.1 = network+1, where the OpenVPN server always sits).
is_assignable_host() {
    local ip net mask network broadcast hub
    ip=$(ip2int "$1"); net=$(ip2int "$2"); mask=$(ip2int "$3")
    ip_in_subnet "$1" "$2" "$3" || return 1
    network=$(( net & mask ))
    broadcast=$(( network | (mask ^ 0xFFFFFFFF) ))
    hub=$(( network + 1 ))
    (( ip != network && ip != broadcast && ip != hub ))
}

#!/bin/bash

set -ex

# Load main settings
cat /default_config/settings.sh
. /default_config/settings.sh
cat /config/settings.sh
. /config/settings.sh

# in re-entry we need to remove the vxlan
# on first entry set a routing rule to the k8s DNS server
if ip addr | grep -q vxlan0; then
  ip link del vxlan0
else
  K8S_GW_IP=${K8S_DEFAULT_GW:-$(/sbin/ip route | awk '/default/ { print $3 }')}
  for local_cidr in $NOT_ROUTED_TO_GATEWAY_CIDRS; do
    # command might fail if rule already set
    ip route add "$local_cidr" via "$K8S_GW_IP" || /bin/true
  done
fi

# Delete default GW to prevent outgoing traffic to leave this docker
echo "Deleting existing default GWs"
ip route del 0/0 || /bin/true

# We don't support IPv6 at the moment, so delete default route to prevent leaking traffic.
echo "Deleting existing default IPv6 route to prevent leakage"
ip -6 route del default || /bin/true

# After this point nothing should be reachable -> check
if ping -c 1 -W 1000 8.8.8.8; then
  echo "WE SHOULD NOT BE ABLE TO PING -> EXIT"
  exit 255
fi

# For debugging reasons print some info
ip addr
ip route

# Handle hostnames in K8s pod environments
if [ -n "$KUBERNETES_SERVICE_HOST" ]; then # if this env var exists, it's probably K8s
  # In Kubernetes, extract the base pod name before the first dash
  HOSTNAME_REAL=$(hostname | cut -d'-' -f1)
else
  # In Docker or other environments, use the full hostname
  HOSTNAME_REAL=$(hostname)
fi
echo $HOSTNAME_REAL

# Derived settings
K8S_DNS_IP="$(cut -d ' ' -f 1 <<< "$K8S_DNS_IPS")"
GATEWAY_IP="$(dig +short "$GATEWAY_NAME" "@${K8S_DNS_IP}")"
NAT_ENTRY="$(grep "^$HOSTNAME_REAL " /config/nat.conf || true)"
VXLAN_GATEWAY_IP="${VXLAN_IP_NETWORK}.1"

# Make sure there is correct route for gateway
# K8S_GW_IP is not set when script is called again and the route should still exist on the pod anyway.
if [ -n "$K8S_GW_IP" ]; then
    ip route add "$GATEWAY_IP" via "$K8S_GW_IP"
fi

# For debugging reasons print some info
ip addr
ip route

# Check we can connect to the GATEWAY IP
ping -c "${CONNECTION_RETRY_COUNT}" "$GATEWAY_IP"

# Create tunnel NIC
ip link add vxlan0 type vxlan id "$VXLAN_ID" dev eth0 dstport "${VXLAN_PORT:-0}" || true
bridge fdb append to 00:00:00:00:00:00 dst "$GATEWAY_IP" dev vxlan0
ip link set up dev vxlan0
if [[ -n "$VPN_INTERFACE_MTU" ]]; then
  ETH0_INTERFACE_MTU=$(cat /sys/class/net/eth0/mtu)
  VXLAN0_INTERFACE_MAX_MTU=$((ETH0_INTERFACE_MTU-50))
  #Ex: if tun0 = 1500 and max mtu is 1450
  if [ ${VPN_INTERFACE_MTU} >= ${VXLAN0_INTERFACE_MAX_MTU} ];then
    ip link set mtu "${VXLAN0_INTERFACE_MAX_MTU}" dev vxlan0
  #Ex: if wg0 = 1420 and max mtu is 1450
  else
    ip link set mtu "${VPN_INTERFACE_MTU}" dev vxlan0
  fi
fi

cat << EOF > /etc/dhclient.conf
backoff-cutoff 2;
initial-interval 1;
reboot 0;
retry 10;
select-timeout 0;
timeout 30;

interface "vxlan0"
 {
  request subnet-mask,
          broadcast-address,
          routers;
          #domain-name-servers;
  require routers,
          subnet-mask;
          #domain-name-servers;
 }
EOF

# Configure IP and default GW though the gateway docker
if [[ -z "$NAT_ENTRY" ]]; then
  echo "Get dynamic IP"
  # cleanup old processes if they exist
  killall -q dhclient || true
  dhclient -v -cf /etc/dhclient.conf vxlan0
else
  IP=$(cut -d' ' -f2 <<< "$NAT_ENTRY")
  VXLAN_IP="${VXLAN_IP_NETWORK}.${IP}"
  echo "Use fixed IP $VXLAN_IP"
  ip addr add "${VXLAN_IP}/24" dev vxlan0
  route add default gw "$VXLAN_GATEWAY_IP"
fi

# For debugging reasons print some info
ip addr
ip route

# Check we can connect to the gateway ussing the vxlan device
ping -c "${CONNECTION_RETRY_COUNT}" "$VXLAN_GATEWAY_IP"

echo "Gateway ready and reachable"

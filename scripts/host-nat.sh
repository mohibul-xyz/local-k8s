#!/usr/bin/env bash
# Makes this host the NAT gateway for the VMs' host-only network.
#
# Traffic from the VM subnet is masqueraded out of whichever interface holds
# the host's default route at that moment (Wi-Fi, Ethernet, VPN, ...), so the
# VMs keep their fixed IPs and keep internet access when the host changes
# networks.
#
# Usage (as root):
#   host-nat.sh install   # install as a systemd service (persists across reboots) and start it
#   host-nat.sh apply     # add the rules now (idempotent)
#   host-nat.sh remove    # delete the rules
#   host-nat.sh status    # show the rules
#   host-nat.sh uninstall # stop and remove the service
#
# Override with env vars: VBOX_NAT_CIDR (default 192.168.56.0/24), VBOX_NAT_IFACE (default vboxnet0)
set -euo pipefail

CIDR="${VBOX_NAT_CIDR:-192.168.56.0/24}"
IFACE="${VBOX_NAT_IFACE:-vboxnet0}"
TAG="vbox-nat"
INSTALL_PATH="/usr/local/sbin/vbox-nat"
UNIT_PATH="/etc/systemd/system/vbox-nat.service"
SYSCTL_PATH="/etc/sysctl.d/90-vbox-nat.conf"

# Each rule as: table chain match...
rules=(
  "nat POSTROUTING -s $CIDR ! -o $IFACE -j MASQUERADE"
  # Inserted at the top of FORWARD so they're evaluated before Docker's and
  # ufw's chains, which both drop forwarded traffic by default.
  "filter FORWARD -i $IFACE -s $CIDR -j ACCEPT"
  "filter FORWARD -o $IFACE -d $CIDR -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
)

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "error: run as root (sudo $0 $1)" >&2
    exit 1
  fi
}

cmd_apply() {
  sysctl -q -w net.ipv4.ip_forward=1
  local rule table chain match
  for rule in "${rules[@]}"; do
    read -r table chain match <<<"$rule"
    # shellcheck disable=SC2086 # match is intentionally word-split
    if ! iptables -t "$table" -C "$chain" $match -m comment --comment "$TAG" 2>/dev/null; then
      iptables -t "$table" -I "$chain" 1 $match -m comment --comment "$TAG"
    fi
  done
  echo "NAT enabled for $CIDR (via $IFACE)."
}

cmd_remove() {
  local rule table chain match
  for rule in "${rules[@]}"; do
    read -r table chain match <<<"$rule"
    # shellcheck disable=SC2086
    while iptables -t "$table" -C "$chain" $match -m comment --comment "$TAG" 2>/dev/null; do
      iptables -t "$table" -D "$chain" $match -m comment --comment "$TAG"
    done
  done
  echo "NAT rules for $CIDR removed."
}

cmd_status() {
  iptables -t nat -S POSTROUTING | grep -- "$TAG" || echo "(no nat rule)"
  iptables -t filter -S FORWARD | grep -- "$TAG" || echo "(no forward rules)"
  echo "ip_forward=$(cat /proc/sys/net/ipv4/ip_forward)"
}

cmd_install() {
  install -m 0755 "$(readlink -f "$0")" "$INSTALL_PATH"
  echo "net.ipv4.ip_forward = 1" >"$SYSCTL_PATH"
  cat >"$UNIT_PATH" <<UNIT
[Unit]
Description=NAT gateway for the VirtualBox host-only network $CIDR
# Start after Docker/ufw so their own rule setup doesn't land above ours.
After=network-online.target docker.service ufw.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=VBOX_NAT_CIDR=$CIDR VBOX_NAT_IFACE=$IFACE
ExecStart=$INSTALL_PATH apply
ExecStop=$INSTALL_PATH remove

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable vbox-nat.service
  systemctl restart vbox-nat.service
  echo "Installed vbox-nat.service."
}

cmd_uninstall() {
  systemctl disable --now vbox-nat.service 2>/dev/null || true
  rm -f "$UNIT_PATH" "$SYSCTL_PATH" "$INSTALL_PATH"
  systemctl daemon-reload
  echo "Uninstalled vbox-nat.service (ip_forward left on; Docker needs it too)."
}

cmd="${1:-}"
case "$cmd" in
  apply | remove | status | install | uninstall)
    need_root "$cmd"
    "cmd_$cmd"
    ;;
  *)
    sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'
    exit 1
    ;;
esac

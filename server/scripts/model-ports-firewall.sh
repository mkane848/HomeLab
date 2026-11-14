#!/usr/bin/env bash
# model-ports-firewall.sh - let only named LAN hosts reach the server's model ports.
#
# Why: llama-server (8090) and Ollama (11434) are published by Docker on every interface and take no API key, so any
# device on the LAN can run inference and load or unload models (found by the 2026-11-09 audit). `ufw` does not help:
# Docker publishes ports through its own rules, ahead of ufw's. Docker's documented place for a rule of your own is
# the DOCKER-USER chain, matched on the ORIGINAL destination port, because the address and port are rewritten before
# the packet reaches it ("Docker with iptables", docs/references.md -> docker-iptables).
#
# What it does: a chain HOMELAB-MODELS that returns for each allowed source and drops everything else, and one jump
# to it from DOCKER-USER per port, only for packets that arrive on the LAN interface in the connection's original
# direction. So nothing else is touched:
#   - the server itself (localhost) and other containers (Open WebUI reaches 8090 over a Docker bridge) do not come
#     in on the LAN interface;
#   - Grocy (9283) and Open WebUI (3000) are not model ports and stay open to the LAN, for the phones;
#   - replies to connections a container opened are in the reply direction.
# It is idempotent: `apply` rebuilds the chain and adds a jump only where one is missing.
#
# The owner's step: it needs root. Runbook: docs/network-topology.md -> "Limit the model ports to named hosts".
#   sudo server/scripts/model-ports-firewall.sh apply              # allow DESKTOP_IP and NODE3_IP from .env
#   sudo server/scripts/model-ports-firewall.sh apply --allow 192.0.2.10,192.0.2.11
#   sudo server/scripts/model-ports-firewall.sh status
#   sudo server/scripts/model-ports-firewall.sh remove             # back to open on the LAN
#        server/scripts/model-ports-firewall.sh apply --dry-run    # print the commands, change nothing (no root)
# Options: --allow ip[,ip...]  --ports p[,p...] (default 8090,11434)  --iface IF (default: the default route's)
#          --env-file FILE (default: <repo>/.env)  --dry-run
# Exit 0 ok, 1 could not apply (no DOCKER-USER chain: not root, or Docker is not running), 3 bad arguments.
#
# IPv4 only. If the LAN hands out IPv6 addresses, check that the ports do not answer over IPv6 (the runbook has the
# command); this script does not cover it. API keys on the engines are still owed before any VPN.
set -euo pipefail

IPT="${IPTABLES:-iptables}"
CHAIN="HOMELAB-MODELS"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

action="${1:-}"
[ $# -gt 0 ] && shift
allow=""; ports="8090,11434"; iface=""; env_file="$repo/.env"; dry=0

die() { echo "model-ports-firewall: $1" >&2; exit "${2:-3}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --allow)    [ $# -ge 2 ] || die "--allow needs a list of addresses"; allow="$2"; shift 2 ;;
    --ports)    [ $# -ge 2 ] || die "--ports needs a list of ports"; ports="$2"; shift 2 ;;
    --iface)    [ $# -ge 2 ] || die "--iface needs an interface name"; iface="$2"; shift 2 ;;
    --env-file) [ $# -ge 2 ] || die "--env-file needs a path"; env_file="$2"; shift 2 ;;
    --dry-run)  dry=1; shift ;;
    *) die "unknown option $1" ;;
  esac
done
case "$action" in apply|remove|status) ;; *) die "usage: $0 apply|remove|status [--allow ip,ip] [--ports p,p] [--iface IF] [--env-file F] [--dry-run]" ;; esac

# One value from an env file: KEY=value, quotes and a trailing comment stripped. Empty when absent.
env_value() {
  [ -f "$env_file" ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$env_file" | head -n 1 | sed -e 's/[[:space:]]*#.*$//' -e 's/^["'"'"']//' -e 's/["'"'"'][[:space:]]*$//' -e 's/[[:space:]]*$//'
}

valid_ipv4() {
  local ip="$1" o
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do [ "$o" -le 255 ] || return 1; done
}

IFS=',' read -r -a port_list <<< "$ports"
[ "${#port_list[@]}" -gt 0 ] || die "no ports given"
for p in "${port_list[@]}"; do
  [[ "$p" =~ ^[0-9]{1,5}$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || die "not a port: '$p'"
done

if [ "$action" = "apply" ]; then
  if [ -z "$allow" ]; then
    d="$(env_value DESKTOP_IP)"; n="$(env_value NODE3_IP)"
    allow="$d${d:+${n:+,}}$n"
  fi
  IFS=',' read -r -a allow_list <<< "$allow"
  # An empty list would shut every LAN host out, the desktop included: refuse rather than guess.
  [ "${#allow_list[@]}" -gt 0 ] || die "no allowed hosts: give --allow ip[,ip...] or set DESKTOP_IP / NODE3_IP in $env_file"
  for ip in "${allow_list[@]}"; do valid_ipv4 "$ip" || die "not an IPv4 address: '$ip'"; done
fi

if [ "$action" != "status" ] && [ -z "$iface" ]; then
  iface="$(ip -o -4 route show to default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}' || true)"
  [ -n "$iface" ] || die "could not find the LAN interface from the default route: give --iface IF"
fi
[ -z "$iface" ] || [[ "$iface" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "not an interface name: '$iface'"

run() { if [ "$dry" = 1 ]; then echo "$IPT $*"; else "$IPT" "$@"; fi; }
jump_spec() { echo "-i $iface -p tcp -m conntrack --ctorigdstport $1 --ctdir ORIGINAL -j $CHAIN"; }

if [ "$action" = "status" ]; then
  "$IPT" -S DOCKER-USER 2>/dev/null || die "no DOCKER-USER chain (run as root, with Docker running)" 1
  "$IPT" -S "$CHAIN" 2>/dev/null || echo "model-ports-firewall: no $CHAIN chain: the model ports are open to the LAN"
  exit 0
fi

if [ "$dry" = 0 ]; then
  "$IPT" -nL DOCKER-USER >/dev/null 2>&1 || die "no DOCKER-USER chain: run with sudo, and with Docker running (it creates the chain)" 1
fi

if [ "$action" = "apply" ]; then
  if [ "$dry" = 1 ]; then
    echo "$IPT -N $CHAIN   # or -F $CHAIN when it exists"
  elif ! "$IPT" -N "$CHAIN" 2>/dev/null; then
    "$IPT" -F "$CHAIN"
  fi
  for ip in "${allow_list[@]}"; do run -A "$CHAIN" -s "$ip" -j RETURN; done
  run -A "$CHAIN" -j DROP
  for p in "${port_list[@]}"; do
    # shellcheck disable=SC2046  # the spec is split into words on purpose
    if [ "$dry" = 1 ] || ! "$IPT" -C DOCKER-USER $(jump_spec "$p") 2>/dev/null; then
      # shellcheck disable=SC2046
      run -I DOCKER-USER $(jump_spec "$p")
    fi
  done
  [ "$dry" = 1 ] || echo "model-ports-firewall: ports $ports on $iface now answer only ${allow_list[*]} (and this host and its containers)"
  exit 0
fi

# remove: every jump for these ports (any number of copies), then the chain.
for p in "${port_list[@]}"; do
  if [ "$dry" = 1 ]; then
    # shellcheck disable=SC2046
    run -D DOCKER-USER $(jump_spec "$p")
  else
    # shellcheck disable=SC2046
    while "$IPT" -C DOCKER-USER $(jump_spec "$p") 2>/dev/null; do "$IPT" -D DOCKER-USER $(jump_spec "$p"); done
  fi
done
if [ "$dry" = 1 ]; then
  run -F "$CHAIN"; run -X "$CHAIN"
elif "$IPT" -nL "$CHAIN" >/dev/null 2>&1; then
  "$IPT" -F "$CHAIN"
  "$IPT" -X "$CHAIN" || die "$CHAIN is still referenced: a jump on another interface or port remains (see: $IPT -S DOCKER-USER)" 1
fi
[ "$dry" = 1 ] || echo "model-ports-firewall: removed; ports $ports are open to the LAN again"

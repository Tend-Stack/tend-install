#!/usr/bin/env bash
# Tend installer, stage 1: the full installer.
#
# Run it through stage 0 (install.sh), which verifies the signed release
# manifest and this file's SHA-256 first and hands over the verified values in
# TEND_M_* variables. Run directly it refuses to do anything.
#
# What it does, in order, each step safe to repeat:
#   1. Checks the machine (root, systemd, OS, memory, disk, ports, Docker).
#   2. Decides the profile: a server on the internet ("vps") or a home server
#      ("home"). Flags --public / --local or TEND_LOCAL_MODE win.
#   3. Patches and hardens a VPS (upgrades, unattended upgrades, fail2ban, ufw).
#   4. Installs upstream Docker if there is none.
#   5. Writes ONE compose stack for both profiles: the panel, the Caddy edge
#      the panel controls, and (home only) the mDNS name announcer. The panel
#      image is pulled by the digest the signed manifest pins.
#   6. Starts it, waits for the panel, then ends with one boxed screen: the
#      address, the setup code and what to do next. If a web proxy (nginx,
#      Apache, Caddy, Traefik, ...) already holds ports 80/443 it offers to stop
#      it (typed `yes`), after the new stack is written; undo commands are
#      saved to $INSTALL_DIR/ports-taken-over.txt.
#
# Addresses: a VPS gets https://tend.<ip-dashed>.sslip.io (a real certificate, no
# domain needed) and http://<ip> redirects there. A home server gets
# https://tend.local, http://tend.local and http://<LAN address>; Docker's
# published ports 80/443 are limited to the home network in the DOCKER-USER
# chain (ufw never sees them), restored at boot by a small systemd unit.
#
# Options: --public | --local, --local-name=<name>, --allow-downgrade,
#          --use-existing-docker, --yes (no questions), --help,
#          --ssh-keys-only (turn SSH password logins off, see below),
#          --keep-ssh-passwords (never offer that),
#          --take-over-ports (stop a web proxy that holds ports 80/443 without
#          asking; it is stopped and kept from starting at boot, never removed)
# Environment: TEND_LOCAL_MODE=1|0, TEND_LOCAL_NAME, TEND_PUBLIC_IP,
#   TEND_HOST_DOMAIN (+ TEND_HOST_DOMAIN_EMAIL) to use your own domain from the
#   start, TEND_SETUP_CODE (automated installs; never written to disk),
#   INSTALL_DIR, TEND_HOST_DATA_DIR, SKIP_HARDENING=1, SKIP_SYSTEM_UPDATE=1.
#
# SSH: password logins are turned off only when you sign in with a key (proven
# from authorized_keys and the sign-in log), you type yes (or pass
# --ssh-keys-only), and sshd accepts the change; --yes alone never does it. The
# setting goes in /etc/ssh/sshd_config.d/00-tend-keys-only.conf and is put back
# if the check fails. Nothing else about SSH is touched, and the installer never
# needs a password or token.

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/tend-host}"
DATA_DIR="${TEND_HOST_DATA_DIR:-/srv/tend-host-data}"
# The control network (172.31.255.0/29): .1 is Docker's gateway, the panel and
# the proxy get fixed addresses. The proxy reaches the panel on its fixed
# address, so every request arrives from CONTROL_IP and the panel trusts that
# one peer (TEND_TRUSTED_PROXIES) to name the real client in X-Forwarded-For.
CONTROL_IP="172.31.255.3"
PANEL_CONTROL_IP="172.31.255.2"
# The edge proxy is pinned here, inside this file the signed manifest pins.
CADDY_IMAGE="caddy:2-alpine@sha256:d8542f48d34a9cf4e4c11a478865229840e87e4c96ea3f439101f31a5d35f75f"
LIB_DIR="/usr/local/lib/tend"
HELPER="/usr/local/bin/tend"
FIREWALL_UNIT="tend-lan-firewall.service"

# ---- output -----------------------------------------------------------------

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then C_STEP=$'\033[1;36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_OFF=$'\033[0m'; C_CODE=$'\033[1;33m'; C_TITLE=$'\033[1;32m'
else C_STEP=""; C_OK=""; C_WARN=""; C_ERR=""; C_OFF=""; C_CODE=""; C_TITLE=""; fi
c_step() { printf '\n%s==> %s%s\n' "$C_STEP" "$*" "$C_OFF"; }
c_ok()   { printf '    %sOK%s  %s\n' "$C_OK" "$C_OFF" "$*"; }
c_warn() { printf '    %s!!%s  %s\n' "$C_WARN" "$C_OFF" "$*"; }
c_err()  { printf '    %sXX%s  %s\n' "$C_ERR" "$C_OFF" "$*" >&2; }
die()    { c_err "$*"; c_err "Fix that and run the same command again; repeating the installer is safe."; exit 1; }
# apt_install / dnf_install: quiet installs; errors still reach the screen.
apt_install() { DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o Dpkg::Use-Pty=0 "$@" > /dev/null; }
dnf_install() { dnf install -y -q "$@" > /dev/null; }
APPLIED=()
record() { APPLIED+=("$1"); }
TAKEOVER=() # front-door proxies to stop: "service<TAB>UNIT<TAB>PROC" or "container<TAB>NAME<TAB>IMAGE<TAB>ID"

# ui_cols: the terminal width ($COLUMNS, else the controlling terminal, else 80).
ui_cols() {
  local c="${COLUMNS:-}"
  if [[ ! $c =~ ^[0-9]+$ ]]; then c="$({ stty size < /dev/tty; } 2> /dev/null | awk '{print $2}')" || c=""; fi
  [[ $c =~ ^[0-9]+$ ]] && ((c > 0)) || c=80
  printf '%s' "$c"
}
# ui_unicode: the heavy box only on a colour terminal that speaks UTF-8.
ui_unicode() { [[ -t 1 && -z ${NO_COLOR:-} ]] && [[ "$(locale charmap 2> /dev/null)" == UTF-8 ]]; }
# ui_box TITLE ROW...: a row is `plain` or `plain<TAB>styled` (the styled text may
# carry colour codes; padding comes from the plain text). A bordered box when the
# terminal is at least 60 columns wide and every row fits 54 characters; else
# borderless, between two rules, so a long address is never cut or wrapped.
ui_box() {
  local title="$1" row plain styled w=0 cols i n tab=$'\t' tl tr bl br h v bar rule
  local -a P=("$title") S=("${C_TITLE:-}${title}${C_OFF:-}")
  shift
  for row in "$@"; do
    plain="${row%%"$tab"*}"; styled="$plain"
    [[ $row != *"$tab"* ]] || styled="${row#*"$tab"}"
    P+=("$plain"); S+=("$styled")
  done
  for plain in "${P[@]}"; do ((${#plain} <= w)) || w=${#plain}; done
  cols="$(ui_cols)"
  if ((cols >= 60 && w <= 54)); then
    if ui_unicode; then tl='┏'; tr='┓'; bl='┗'; br='┛'; h='━'; v='┃'; else tl='+'; tr='+'; bl='+'; br='+'; h='-'; v='|'; fi
    printf -v bar '%*s' $((w + 2)) ''; bar="${bar// /$h}"
    printf '%s%s%s%s%s\n' "${C_TITLE:-}" "$tl" "$bar" "$tr" "${C_OFF:-}"
    for i in "${!P[@]}"; do
      n=$((w - ${#P[i]}))
      printf '%s%s%s %s%*s %s%s%s\n' "${C_TITLE:-}" "$v" "${C_OFF:-}" "${S[i]}" "$n" "" "${C_TITLE:-}" "$v" "${C_OFF:-}"
    done
    printf '%s%s%s%s%s\n' "${C_TITLE:-}" "$bl" "$bar" "$br" "${C_OFF:-}"
  else
    printf -v rule '%*s' $((cols < 58 ? cols : 58)) ''; rule="${rule// /=}"
    printf '%s\n' "$rule"
    for i in "${!P[@]}"; do if [[ -z ${P[i]} ]]; then echo; else printf '  %s\n' "${S[i]}"; fi; done
    printf '%s\n' "$rule"
  fi
}

# ---- pure functions (no side effects; tested in test/install-test.sh) --------

# version_cmp A B: prints -1, 0 or 1. X.Y.Z with an optional -(alpha|beta|rc).N.
version_cmp() {
  local a="$1" b="$2" ca cb pa="" pb="" i x y
  ca="${a%%-*}"; cb="${b%%-*}"
  [[ $a == *-* ]] && pa="${a#*-}"
  [[ $b == *-* ]] && pb="${b#*-}"
  local -a xa xb
  IFS=. read -r -a xa <<< "$ca"; IFS=. read -r -a xb <<< "$cb"
  for i in 0 1 2; do
    x=$((10#${xa[i]:-0})); y=$((10#${xb[i]:-0}))
    if ((x < y)); then echo -1; return; elif ((x > y)); then echo 1; return; fi
  done
  if [[ -z $pa && -z $pb ]]; then echo 0; return; fi
  if [[ -z $pa ]]; then echo 1; return; fi   # a release is newer than its prereleases
  if [[ -z $pb ]]; then echo -1; return; fi
  x="$(pre_rank "$pa")"; y="$(pre_rank "$pb")"
  if ((x < y)); then echo -1; elif ((x > y)); then echo 1; else echo 0; fi
}
# pre_rank beta.2 -> a sortable integer (alpha < beta < rc, then the number).
pre_rank() {
  local tag="${1%%.*}" n="${1#*.}" t=0
  case "$tag" in alpha) t=1 ;; beta) t=2 ;; rc) t=3 ;; esac
  echo $((t * 1000000 + 10#${n:-0}))
}

is_ipv4() {
  local o
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do ((10#$o <= 255)) || return 1; done
}
is_ipv6() { [[ $1 == *:*:* && $1 =~ ^[0-9A-Fa-f:]+$ ]]; }

# is_lan_ipv4: RFC 1918 only (what a home router hands out).
is_lan_ipv4() {
  is_ipv4 "$1" || return 1
  case "$1" in 10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[01].*) return 0 ;; esac
  return 1
}
# is_public_ipv4: routable on the internet (not private, shared, loopback,
# link-local, documentation, benchmarking, multicast or reserved space).
is_public_ipv4() {
  is_ipv4 "$1" || return 1
  is_lan_ipv4 "$1" && return 1
  local a b
  IFS=. read -r a b _ <<< "$1"; a=$((10#$a)); b=$((10#$b))
  ((a == 0 || a == 127 || a >= 224)) && return 1
  ((a == 100 && b >= 64 && b <= 127)) && return 1
  ((a == 169 && b == 254)) && return 1
  ((a == 198 && (b == 18 || b == 19))) && return 1
  [[ $1 == 192.0.0.* || $1 == 192.0.2.* || $1 == 198.51.100.* || $1 == 203.0.113.* ]] && return 1
  return 0
}
# ip_dashed ADDR: sslip.io's spelling (dots or colons become dashes).
ip_dashed() { local s="${1,,}"; s="${s//./-}"; printf '%s' "${s//:/-}"; }
sslip_name() { printf 'tend.%s.sslip.io' "$(ip_dashed "$1")"; }

# saved_panel_fqdn STATE PUBLIC_IP: the address an earlier install of this
# machine used, printed when it is still right and nothing is printed otherwise.
# An upgrade without TEND_HOST_DOMAIN keeps that name: bookmarks and passkeys are
# bound to it (the first release named it tend-<ip>, this one tend.<ip>). A saved
# sslip.io name for another IP is stale and dropped; an own domain is kept.
saved_panel_fqdn() {
  local state="$1" ip="$2" prof fqdn dashed
  [[ -f $state ]] || return 0
  prof="$(state_get "$state" profile || true)"; fqdn="$(state_get "$state" fqdn || true)"
  [[ $prof == vps ]] || return 0
  dashed="$(ip_dashed "$ip")"
  if [[ -z $fqdn ]]; then
    # An older state file without the name: the first release's own name.
    [[ -n $(state_get "$state" version || true) ]] && printf 'tend-%s.sslip.io' "$dashed"
    return 0
  fi
  fqdn="${fqdn,,}"
  if [[ $fqdn == *.sslip.io ]]; then
    [[ $fqdn == "tend.$dashed.sslip.io" || $fqdn == "tend-$dashed.sslip.io" ]] || return 0
  fi
  printf '%s' "$fqdn"
}

# parse_trace_ip: reads Cloudflare's /cdn-cgi/trace text on stdin, prints ip=.
parse_trace_ip() {
  local line ip
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ $line == ip=* ]] || continue
    ip="${line#ip=}"
    if is_ipv4 "$ip" || is_ipv6 "$ip"; then printf '%s' "$ip"; return 0; fi
  done
  return 1
}

# interface_addrs KIND: reads `ip -o -4 addr show scope global` on stdin and
# prints the IPv4 addresses on real interfaces (not container bridges, tunnels
# or VPN overlays) that are KIND = public | lan.
interface_addrs() {
  local addr ip
  while read -r addr; do
    ip="${addr%/*}"
    case "$1" in public) is_public_ipv4 "$ip" && echo "$ip" ;; lan) is_lan_ipv4 "$ip" && echo "$ip" ;; esac
  done < <(awk '$2 !~ /^(docker|br-|veth|virbr|tailscale|wg|zt|tun|tap|cni|flannel|lo)/ {print $4}')
  return 0
}

# resolve_profile OVERRIDE HAS_DOMAIN PUBLIC_IFACE METADATA: prints "vps" or "home".
# OVERRIDE is 1 (home), 0 (vps) or empty; the others are 1 or 0. First match wins.
resolve_profile() {
  if [[ $1 == 1 ]]; then echo home; return; fi
  if [[ $1 == 0 || $2 == 1 || $3 == 1 || $4 == 1 ]]; then echo vps; return; fi
  echo home
}

normalize_local_name() {
  local n
  n="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  n="${n%.}"; n="${n%.local}"
  [[ $n =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || return 1
  printf '%s' "$n"
}

# format_code: 7kq2m9xd4trb -> 7KQ2-M9XD-4TRB
format_code() {
  local c="${1//[^A-Za-z0-9]/}" out="" i
  c="${c^^}"
  for ((i = 0; i < ${#c}; i += 4)); do out+="${out:+-}${c:i:4}"; done
  printf '%s' "$out"
}
# valid_setup_code: at least 12 characters once spaces and hyphens are dropped.
valid_setup_code() { local c="${1//[ -]/}"; ((${#c} >= 12)); }

# os_support ID VERSION_ID: prints tier1, tier2 or no.
os_support() {
  local id="$1" v="$2" major="${2%%.*}"
  [[ $major =~ ^[0-9]+$ ]] || { echo no; return; }
  case "$id" in
    debian) if ((major == 12 || major == 13)); then echo tier1; elif ((major > 13)); then echo tier2; else echo no; fi ;;
    ubuntu) if [[ $v == 22.04 || $v == 24.04 ]]; then echo tier1; elif [[ $(version_cmp "$v.0" 22.4.0) == 1 ]]; then echo tier2; else echo no; fi ;;
    rocky | almalinux | rhel | centos) if ((major >= 9)); then echo tier2; else echo no; fi ;;
    fedora) if ((major >= 39)); then echo tier2; else echo no; fi ;;
    *) echo no ;;
  esac
}
# mem_verdict KB: ok (>= ~2 GiB), warn (>= ~0.8 GiB), refuse.
mem_verdict() { if (($1 >= 1800000)); then echo ok; elif (($1 >= 800000)); then echo warn; else echo refuse; fi; }
# disk_ok KB: at least 10 GiB free.
disk_ok() { (($1 >= 10485760)); }

# --- state file (.tend-install.json): canonical, one field per line ---
render_state() { # version digest channel profile fqdn local_name public_ip lan_ip image
  printf '{\n  "channel": "%s",\n  "fqdn": "%s",\n  "image": "%s",\n  "image_digest": "%s",\n  "lan_ip": "%s",\n  "local_name": "%s",\n  "profile": "%s",\n  "public_ip": "%s",\n  "version": "%s"\n}\n' \
    "$3" "$5" "$9" "$2" "$8" "$6" "$4" "$7" "$1"
}
state_get() { # state_get FILE KEY
  local line
  line="$(grep -E "^  \"$2\": " "$1" 2> /dev/null | head -1)" || return 1
  line="${line#*: }"; line="${line%,}"; line="${line#\"}"; line="${line%\"}"
  printf '%s' "$line"
}

# --- generated files ---
# render_caddyfile PROFILE FQDN IPS EMAIL: the edge proxy's bootstrap file. It
# holds the https site; the panel adds the http and IP routes (the public IP's
# redirect, the LAN addresses) through the admin API after its first start, and
# folds any other server (the plain-http site below) into its own.
#   vps : FQDN = the https name; IPS = the public IPv4. When known, plain http on
#         that bare IP is redirected to the https name (308, the panel's own
#         status) so the first minutes after install, before the panel's first
#         successful edge sync, do not answer Caddy's generic redirect to
#         https://<ip>/ (no certificate exists for it).
#   home: FQDN = tend.local. IPS is unused: no IP is written here.
render_caddyfile() {
  local profile="$1" fqdn="$2" ips="${3:-}" email="${4:-}"
  printf '# Generated by the Tend installer. The panel replaces these routes through the admin API.\n'
  # shellcheck disable=SC2016  # {$VAR} is Caddy's own placeholder
  printf '{\n\tadmin {$TEND_CADDY_CONTROL_IP}:2019\n\tskip_install_trust\n'
  [[ -z $email ]] || printf '\temail %s\n' "$email"
  printf '}\n\n(panel) {\n\treverse_proxy %s:8787 {\n\t\tflush_interval -1\n\t}\n\tencode gzip\n}\n\n' "$PANEL_CONTROL_IP"
  if [[ $profile == vps ]]; then
    printf '%s {\n\timport panel\n}\n' "$fqdn"
    if is_ipv4 "$ips"; then printf '\nhttp://%s {\n\tredir https://%s{uri} 308\n}\n' "$ips" "$fqdn"; fi
  else
    printf 'https://%s {\n\ttls internal\n\timport panel\n}\n' "$fqdn"
  fi
}

# render_env: the compose variables (no secrets). The setup code is never here.
render_env() { # image profile fqdn public_ip local_name
  printf '# Generated by the Tend installer; re-running it rewrites this file.\n'
  printf 'TEND_IMAGE=%s\nCADDY_IMAGE=%s\nTEND_DATA_DIR=%s\nTEND_CADDY_CONTROL_IP=%s\nTEND_PANEL_CONTROL_IP=%s\n' "$1" "$CADDY_IMAGE" "$DATA_DIR" "$CONTROL_IP" "$PANEL_CONTROL_IP"
  # First-start seeds: the panel reads them once, on its first start. Changing
  # them later changes nothing; the address is changed in the panel itself.
  # (TEND_PANEL_FQDN is no longer written: it would claim the address for good.)
  if [[ $2 == home ]]; then
    printf 'TEND_INSTALL_PROFILE=home\nTEND_SEED_PANEL_ADDRESS=\nTEND_SEED_PUBLIC_IP=\n'
    printf 'COMPOSE_PROFILES=local\nTEND_LOCAL_MODE=1\nTEND_LOCAL_NAME=%s.local\n' "$5"
  else
    printf 'TEND_INSTALL_PROFILE=vps\nTEND_SEED_PANEL_ADDRESS=%s\nTEND_SEED_PUBLIC_IP=%s\n' "$3" "$4"
    printf 'TEND_LOCAL_MODE=0\nTEND_LOCAL_NAME=\n'
  fi
  # Self-update from the signed channel. The development switch and key are
  # written only when the installer itself was run behind TEND_INSTALL_DEV=1 with
  # a test key; in every other install they are empty and the panel trusts only
  # the keys compiled into its binary.
  printf 'TEND_UPDATE_CHANNEL=%s\n' "${TEND_CHANNEL:-stable}"
  if [[ ${TEND_INSTALL_DEV:-} == 1 && -n ${TEND_INSTALL_DEV_KEY:-} ]]; then
    printf 'TEND_UPDATE_DEV=1\nTEND_UPDATE_DEV_KEY=%s\nTEND_UPDATE_BASE=%s\n' "$TEND_INSTALL_DEV_KEY" "${TEND_UPDATE_BASE:-${TEND_INSTALL_BASE:-}}"
  else
    printf 'TEND_UPDATE_DEV=\nTEND_UPDATE_DEV_KEY=\nTEND_UPDATE_BASE=\n'
  fi
}

render_compose() {
  cat << 'EOF'
# Tend: one stack for every profile. Generated by the Tend installer from the
# signed release; it matches docker-compose.ghcr.yml. Values are in .env.
# Edit and `docker compose up -d` to apply; re-running the installer rewrites it.
services:
  tend-host:
    image: ${TEND_IMAGE}
    container_name: tend-host
    restart: unless-stopped
    expose:
      - "8787"
    environment:
      HOST: 0.0.0.0
      PORT: "8787"
      LOG_LEVEL: INFO
      TEND_HOST_DATA_DIR: /srv/data
      TEND_CADDY_ADMIN_URL: http://${TEND_CADDY_CONTROL_IP}:2019
      # The proxy reaches the panel on this fixed address, and only it is
      # trusted to name the real client (the setup-code lockout counts per client).
      TEND_PANEL_UPSTREAM: ${TEND_PANEL_CONTROL_IP}:8787
      TEND_TRUSTED_PROXIES: ${TEND_CADDY_CONTROL_IP}
      # Read once, on the first start (internal/api/first_boot.go).
      TEND_INSTALL_PROFILE: ${TEND_INSTALL_PROFILE:-}
      TEND_SEED_PANEL_ADDRESS: ${TEND_SEED_PANEL_ADDRESS:-}
      TEND_SEED_PUBLIC_IP: ${TEND_SEED_PUBLIC_IP:-}
      TEND_LOCAL_MODE: ${TEND_LOCAL_MODE:-}
      TEND_LOCAL_NAME: ${TEND_LOCAL_NAME:-}
      TEND_LOCALNET_DIR: /srv/localnet
      # Automated installs only; empty means the panel generates a code.
      TEND_SETUP_CODE: ${TEND_SETUP_CODE:-}
      # Updates: pull the next signed release by digest (internal/selfupdate).
      # The host helper runs from this same pinned image, not a Docker Hub tag.
      TEND_SELF_UPDATE_MODE: channel
      TEND_UPDATE_CHANNEL: ${TEND_UPDATE_CHANNEL:-stable}
      TEND_UPDATE_BASE: ${TEND_UPDATE_BASE:-}
      TEND_UPDATE_DEV: ${TEND_UPDATE_DEV:-}
      TEND_UPDATE_DEV_KEY: ${TEND_UPDATE_DEV_KEY:-}
      TEND_HOST_EXEC_IMAGE: ${TEND_IMAGE}
    volumes:
      - ${TEND_DATA_DIR}:/srv/data
      - /var/run/docker.sock:/var/run/docker.sock
      - ${TEND_DATA_DIR}/localnet:/srv/localnet
    networks:
      edge:
      control:
        ipv4_address: ${TEND_PANEL_CONTROL_IP}
      tend-net:

  caddy:
    image: ${CADDY_IMAGE}
    container_name: tend-caddy
    restart: unless-stopped
    environment:
      TEND_CADDY_CONTROL_IP: ${TEND_CADDY_CONTROL_IP}
    ports:
      # IPv4 only: a published IPv6 port would reach Caddy through the host's
      # INPUT path, outside the home-network rule.
      - "0.0.0.0:80:80"
      - "0.0.0.0:443:443"
      - "0.0.0.0:443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
    depends_on: [tend-host]
    networks:
      edge:
      control:
        ipv4_address: ${TEND_CADDY_CONTROL_IP}
      tend-net:

  # Home profile only (COMPOSE_PROFILES=local): announces tend.local and the
  # apps' names over mDNS. Multicast needs the host network, so this one small
  # process gets it and nothing else: no Docker socket, no data, no capabilities.
  tend-mdns:
    profiles: ["local"]
    image: ${TEND_IMAGE}
    container_name: tend-mdns
    restart: unless-stopped
    command: ["mdns", "--dir", "/srv/localnet"]
    network_mode: host
    read_only: true
    cap_drop: ["ALL"]
    security_opt: ["no-new-privileges:true"]
    healthcheck:
      disable: true
    volumes:
      - ${TEND_DATA_DIR}/localnet:/srv/localnet
    depends_on: [tend-host]

volumes:
  caddy-data:
    name: tend-caddy-data
  caddy-config:
    name: tend-caddy-config

networks:
  edge:
    driver: bridge
  control:
    driver: bridge
    ipam:
      config:
        - subnet: 172.31.255.0/29
  tend-net:
    name: tend-net
    external: true
EOF
}

# render_lan_firewall: the script the systemd unit runs. Docker publishes ports
# through NAT, so ufw's INPUT rules never see them. This limits the web ports
# to home-network sources in DOCKER-USER, the chain Docker reserves for that.
render_lan_firewall() {
  cat << 'EOF'
#!/bin/sh
# Generated by the Tend installer: keeps Tend's web ports (80, 443) on the home network.
# Usage: lan-firewall.sh apply | remove
set -eu
ipt=iptables
rules() { # rules add|del: the jumps into TEND-LAN, one per published port
  for spec in "tcp 80" "tcp 443" "udp 443"; do
    proto="${spec% *}"; port="${spec#* }"
    set -- -p "$proto" -m conntrack --ctstate DNAT --ctorigdstport "$port" --ctdir ORIGINAL -j TEND-LAN
    if [ "$ACTION" = add ]; then "$ipt" -C DOCKER-USER "$@" 2> /dev/null || "$ipt" -I DOCKER-USER 1 "$@"
    else while "$ipt" -C DOCKER-USER "$@" 2> /dev/null; do "$ipt" -D DOCKER-USER "$@"; done; fi
  done
}
case "${1:-}" in
  apply)
    "$ipt" -N DOCKER-USER 2> /dev/null || true
    "$ipt" -N TEND-LAN 2> /dev/null || true
    "$ipt" -F TEND-LAN
    for net in 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do "$ipt" -A TEND-LAN -s "$net" -j RETURN; done
    "$ipt" -A TEND-LAN -j DROP
    ACTION=add; rules ;;
  remove)
    if "$ipt" -n -L DOCKER-USER > /dev/null 2>&1; then ACTION=del; rules; fi
    "$ipt" -F TEND-LAN 2> /dev/null || true
    "$ipt" -X TEND-LAN 2> /dev/null || true ;;
  *) echo "usage: $0 apply|remove" >&2; exit 2 ;;
esac
EOF
}

render_lan_firewall_unit() {
  cat << EOF
[Unit]
Description=Keep Tend's web ports on the home network
Before=docker.service
After=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$LIB_DIR/lan-firewall.sh apply

[Install]
WantedBy=multi-user.target
EOF
}

# render_helper: /usr/local/bin/tend, the day-two command.
render_helper() {
  printf '#!/usr/bin/env bash\n# Generated by the Tend installer.\nINSTALL_DIR=%q\n' "$INSTALL_DIR"
  declare -f ui_cols ui_unicode ui_box
  cat << 'EOF'
set -euo pipefail
C_TITLE=""; C_OFF=""
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then C_TITLE=$'\033[1;32m'; C_OFF=$'\033[0m'; fi
STATE="$INSTALL_DIR/.tend-install.json"
sget() { local l; l="$(grep -E "^  \"$1\": " "$STATE" 2> /dev/null | head -1)" || return 0; l="${l#*: }"; l="${l%,}"; l="${l#\"}"; printf '%s' "${l%\"}"; }
[[ -f $STATE ]] || { echo "Tend is not installed here (no $STATE)." >&2; exit 1; }
if [[ $EUID -ne 0 && -z ${SUDO_COMMAND:-} ]]; then exec sudo "$0" "$@"; fi
DATA_DIR="$(grep -E '^TEND_DATA_DIR=' "$INSTALL_DIR/.env" | cut -d= -f2-)"
CODE_FILE="$DATA_DIR/first-run-setup-code"
dc() { (cd "$INSTALL_DIR" && docker compose "$@"); }
healthy() { docker exec tend-host curl -fsS http://127.0.0.1:8787/healthz > /dev/null 2>&1; }
first_run() { docker exec tend-host curl -fsS http://127.0.0.1:8787/api/auth/setup-status 2> /dev/null | grep -q '"first_run":[[:space:]]*true'; }
fmt() { local c="${1//[^A-Za-z0-9]/}" o="" i; c="${c^^}"; for ((i = 0; i < ${#c}; i += 4)); do o+="${o:+-}${c:i:4}"; done; printf '%s' "$o"; }

# The engine answers `tend <command>` only when the image carries this marker:
# an older engine ignores an unknown word and would start a second server on
# the same data.
engine_cli() { docker exec tend-host test -e /usr/local/share/tend/cli-v1 > /dev/null 2>&1; }

addresses() {
  local out
  if engine_cli && out="$(docker exec tend-host tend address 2> /dev/null)" && [[ -n $out ]]; then printf '%s\n' "$out"; return; fi
  if [[ "$(sget profile)" == home ]]; then
    echo "https://$(sget local_name)"; [[ -z "$(sget lan_ip)" ]] || echo "http://$(sget lan_ip)"
  else
    echo "https://$(sget fqdn)"; [[ -z "$(sget public_ip)" ]] || echo "http://$(sget public_ip)  (redirects to the address above)"
  fi
}

# Puts the installed address back as the current one (the way out of a move
# that went wrong); the engine does it, so an older engine cannot.
address_reset() {
  if ! engine_cli; then echo "This version of Tend cannot do that yet. Update first: sudo tend update" >&2; exit 1; fi
  docker exec tend-host tend address --reset || exit $?
}

# `tend address [--current|--json|--reset]`: the engine's own list of
# addresses; without a word, the same as `addresses`.
address_cmd() {
  case "${1:-}" in
    "") addresses ;;
    --reset) address_reset ;;
    *)
      if ! engine_cli; then echo "This version of Tend cannot do that yet. Update first: sudo tend update" >&2; exit 1; fi
      docker exec tend-host tend address "$@" || exit $?
      ;;
  esac
}

setup_code() {
  local fresh=0
  if ! healthy; then echo "The panel is not running. Try: sudo tend status" >&2; exit 1; fi
  if engine_cli; then
    # The engine shows or rotates the code itself and says why when there is none.
    docker exec tend-host tend setup-code "$@" || exit $?
    exit 0
  fi
  [[ ${1:-} != --new ]] || fresh=1
  if ! first_run; then echo "Tend already has an administrator, so there is no setup code."; exit 0; fi
  if ((fresh)); then
    rm -f "$CODE_FILE"; docker restart tend-host > /dev/null
    for _ in $(seq 1 40); do healthy && break; sleep 2; done
    echo "A new setup code was made; the old one no longer works."
  fi
  for _ in 1 2 3 4 5; do [[ -s $CODE_FILE ]] && break; sleep 1; done
  if [[ -s $CODE_FILE ]]; then echo "Setup code: $(fmt "$(< "$CODE_FILE")")"
  else echo "The code was set with TEND_SETUP_CODE when Tend was installed; it is not stored. Re-run the installer without it to get a generated one." >&2; exit 1; fi
}

# `tend reset-admin`: the engine makes a one-time link; this draws it in the same
# box as the end of the install. Its own words (no account yet, several admins,
# too many links) and exit status pass through untouched.
reset_admin() {
  local out rc=0 link="" rpath="" account="" two="" line tokens="Other sign-ins stop working." arg
  if ! healthy; then echo "The panel is not running. Try: sudo tend status" >&2; exit 1; fi
  if ! docker exec tend-host test -e /usr/local/share/tend/cli-v2 > /dev/null 2>&1; then
    echo "This version of Tend cannot do that yet. Update first: sudo tend update" >&2; exit 1
  fi
  out="$(docker exec tend-host tend reset-admin "$@")" || rc=$?
  if ((rc != 0)); then [[ -z $out ]] || printf '%s\n' "$out"; exit "$rc"; fi
  while IFS= read -r line; do
    case "$line" in
      "Reset link: "*) link="${line#Reset link: }" ;;
      "Reset path: "*) rpath="${line#Reset path: }" ;;
      "Account: "*) account="${line#Account: }" ;;
      "Two-step sign-in: "*) two="${line#Two-step sign-in: }" ;;
    esac
  done <<< "$out"
  if [[ -z $link && -z $rpath ]]; then printf '%s\n' "$out"; return 0; fi
  for arg in "$@"; do [[ $arg != --revoke-tokens ]] || tokens="Other sign-ins and API tokens stop working."; done
  local -a rows=("")
  rows+=("1. Open this link in a browser." "   It works once, for 15 minutes:")
  if [[ -n $link ]]; then rows+=("$link"); else rows+=("Open your Tend address and add this to the end:" "$rpath"); fi
  rows+=("" "2. Choose a new password, then sign in.")
  if [[ $two == reset ]]; then rows+=("Two-step sign-in was reset: Tend will set it up again.")
  else rows+=("Two-step sign-in stays on: keep your phone ready."); fi
  rows+=("$tokens")
  echo
  ui_box "Password reset for ${account:-the administrator}" "${rows[@]}"
}

uninstall() {
  local purge=0 ans
  [[ ${1:-} != --purge ]] || purge=1
  if ((purge)); then
    echo "This removes Tend AND all of its data: accounts, settings, backups made by the panel, certificates."
    echo "Apps the panel deployed keep running as plain containers. Type the word delete to continue:"
    read -r ans < /dev/tty || ans=""; [[ $ans == delete ]] || { echo "Nothing was removed."; exit 1; }
  else
    echo "This stops and removes Tend's containers. Your data stays in $DATA_DIR, so installing again picks it up."
    printf 'Continue? [y/N] '; read -r ans < /dev/tty || ans=""; [[ ${ans,,} == y* ]] || { echo "Nothing was removed."; exit 1; }
  fi
  if ((purge)); then dc --progress quiet down -v --remove-orphans || true; else dc --progress quiet down --remove-orphans || true; fi
  systemctl disable --now tend-lan-firewall.service 2> /dev/null || true
  [[ ! -x /usr/local/lib/tend/lan-firewall.sh ]] || /usr/local/lib/tend/lan-firewall.sh remove || true
  rm -f /etc/systemd/system/tend-lan-firewall.service; systemctl daemon-reload 2> /dev/null || true
  rm -rf /usr/local/lib/tend
  rm -f /etc/update-motd.d/60-tend /etc/profile.d/tend-claim.sh
  if ((purge)); then rm -rf "$DATA_DIR"; fi
  rm -rf "$INSTALL_DIR"
  echo "Tend is removed. Docker, the firewall rules for SSH and any apps the panel deployed were left alone."
  if ((!purge)); then echo "Data kept: $DATA_DIR  (remove it for good with: sudo rm -rf $DATA_DIR)"; fi
  rm -f /usr/local/bin/tend
}

case "${1:-help}" in
  status) echo "Tend $(sget version) ($(sget profile) profile)"; addresses; dc ps; healthy && echo "Panel: healthy" || echo "Panel: NOT answering" ;;
  setup-code) shift; setup_code "$@" ;;
  addresses) addresses ;;
  address-reset) address_reset ;;
  address) shift; address_cmd "$@" ;;
  reset-admin) shift; reset_admin "$@" ;;
  logs) shift; dc logs "$@" ;;
  update) shift; curl -fsSL "${TEND_INSTALL_BASE:-https://get.tend.host}/install.sh" | TEND_CHANNEL="$(sget channel)" bash -s -- "$@" ;;
  uninstall) shift; uninstall "${1:-}" ;;
  *) cat << 'USAGE'
usage: sudo tend <command>
  status              what is running and the addresses
  addresses           where to open Tend
  address             where to open Tend, as the panel knows it (--current, --json)
  address --reset     go back to the address Tend was installed with
  setup-code          show the first-run setup code (while no account exists)
  setup-code --new    make a new one; the old code stops working
  reset-admin         make a one-time link to set a new admin password
  update              install the newest signed release
  logs [args]         container logs (docker compose logs)
  uninstall           remove Tend, keep its data
  uninstall --purge   remove Tend and its data (asks you to type: delete)
USAGE
  ;;
esac
EOF
}

# ---- machine and network facts (side-effect free reads) ---------------------

meta_answers() { curl -s -o /dev/null -m 1 -w '%{http_code}' http://169.254.169.254/ 2> /dev/null | grep -qv '^000$'; }
detect_public_ip() {
  local ip="" t
  if [[ -n ${TEND_PUBLIC_IP:-} ]]; then printf '%s' "$TEND_PUBLIC_IP"; return; fi
  t="$(curl -4 -fsS -m 6 https://1.1.1.1/cdn-cgi/trace 2> /dev/null || true)"
  ip="$(parse_trace_ip <<< "$t" || true)"
  [[ -n $ip ]] || ip="$(ip -o -4 addr show scope global 2> /dev/null | interface_addrs public | head -1)"
  printf '%s' "$ip"
}
tty_ok() { [[ -r /dev/tty ]] && { : < /dev/tty; } 2> /dev/null; }
ask() { # ask PROMPT DEFAULT(Y|N): returns 0 for yes
  local ans="" d="$2"
  if [[ $ASSUME_YES == 1 ]] || ! tty_ok; then [[ $d == Y ]]; return; fi
  printf '\n    %s [%s] ' "$1" "$([[ $d == Y ]] && echo Y/n || echo y/N)" > /dev/tty
  read -r ans < /dev/tty || ans=""
  case "${ans,,}" in y | yes) return 0 ;; n | no) return 1 ;; *) [[ $d == Y ]] ;; esac
}
tty_line() { local l=""; read -r l < /dev/tty || true; printf '%s' "$l"; } # one line typed on the terminal

# ---- who holds ports 80 and 443 -----------------------------------------------

PROC_ROOT="${PROC_ROOT:-/proc}"

# parse_ss_users LINE: "name pid" of the first process on an `ss -ltnp` line.
parse_ss_users() {
  local re='users:\(\("([^"]*)",pid=([0-9]+)'
  [[ $1 =~ $re ]] || return 1
  printf '%s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}
# unit_of_pid PID: the systemd service a process runs in (from its cgroup).
unit_of_pid() {
  local f="$PROC_ROOT/$1/cgroup" line part unit=""
  local -a parts
  [[ -r $f ]] || return 1
  while IFS= read -r line; do
    line="${line#*:*:}"
    IFS=/ read -r -a parts <<< "$line"
    for part in "${parts[@]}"; do [[ $part != *.service ]] || unit="$part"; done
  done < "$f"
  [[ -n $unit ]] || return 1
  printf '%s' "$unit"
}
# container_of_pid PID: the 64-hex container id a process runs in, if any.
container_of_pid() {
  local f="$PROC_ROOT/$1/cgroup" id
  [[ -r $f ]] || return 1
  id="$(grep -Eo '[0-9a-f]{64}' "$f" | head -1)" || id=""
  [[ -n $id ]] || return 1
  printf '%s' "$id"
}
# docker_ps_table: one line per running container: ID, name, image, ports (tab separated).
docker_ps_table() {
  command -v docker > /dev/null 2>&1 || return 0
  docker ps --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Ports}}' 2> /dev/null || true
}
# docker_port_owners PORT: "name<TAB>image<TAB>id" of each container that publishes PORT.
docker_port_owners() {
  local id name image ports
  while IFS=$'\t' read -r id name image ports; do
    [[ $ports == *":$1->"* ]] || continue
    printf '%s\t%s\t%s\n' "$name" "$image" "$id"
  done < <(docker_ps_table)
}
# port_owner PORT: none | tend | container<TAB>NAME<TAB>IMAGE<TAB>ID |
# service<TAB>UNIT<TAB>PROC | process<TAB>PROC<TAB>PID.
port_owner() {
  local port="$1" n img id line np name pid unit cid
  while IFS=$'\t' read -r n img id; do
    if [[ $n == tend-caddy ]]; then printf 'tend\n'; return 0; fi
    printf 'container\t%s\t%s\t%s\n' "$n" "$img" "$id"; return 0
  done < <(docker_port_owners "$port")
  line="$(ss -ltnpH "sport = :$port" 2> /dev/null | head -1 || true)"
  [[ -n $line ]] || { printf 'none\n'; return 0; }
  np="$(parse_ss_users "$line" || true)"
  [[ -n $np ]] || { printf 'process\tunknown\t-\n'; return 0; }
  name="${np% *}"; pid="${np##* }"
  if [[ $name != docker-proxy ]]; then
    if cid="$(container_of_pid "$pid")"; then
      while IFS=$'\t' read -r id n img _; do
        [[ -n $id && $cid == "$id"* ]] || continue
        if [[ $n == tend-caddy ]]; then printf 'tend\n'; else printf 'container\t%s\t%s\t%s\n' "$n" "$img" "$id"; fi
        return 0
      done < <(docker_ps_table)
    fi
    if unit="$(unit_of_pid "$pid")"; then printf 'service\t%s\t%s\n' "$unit" "$name"; return 0; fi
  fi
  printf 'process\t%s\t%s\n' "$name" "$pid"
}
# proxy_eligible KIND NAME IMAGE: only a web proxy may be stopped for the user.
proxy_eligible() {
  local img
  case "$1" in
    service) case "$2" in nginx.service | apache2.service | httpd.service | caddy.service | lighttpd.service | haproxy.service | traefik.service) return 0 ;; esac ;;
    container)
      img="${3%%@*}"; img="${img##*/}"; img="${img%%:*}"; img="${img,,}"
      case "$img" in nginx* | traefik | caddy | haproxy | httpd | openresty | swag) return 0 ;; esac
      ;;
  esac
  return 1
}
# other_panel: prints the name of another hosting panel on this machine (return 0), or returns 1.
other_panel() {
  local root="${FS_ROOT:-}" d id name image k hay
  for d in cpanel:cPanel psa:Plesk hestia:HestiaCP CyberCP:CyberPanel; do
    if [[ -d $root/usr/local/${d%%:*} ]]; then printf '%s' "${d#*:}"; return 0; fi
  done
  while IFS=$'\t' read -r id name image _; do
    hay="${name,,} ${image,,}"
    for k in coolify:Coolify caprover:CapRover captain-captain:CapRover dokploy:Dokploy easypanel:Easypanel runtipi:Runtipi; do
      if [[ $hay == *"${k%%:*}"* ]]; then printf '%s' "${k#*:}"; return 0; fi
    done
  done < <(docker_ps_table)
  return 1
}
# owner_text KIND A B: how the screen names a port owner.
owner_text() {
  case "$1" in
    container) printf 'the container %s (%s)' "$2" "$3" ;;
    service) printf 'the service %s (%s)' "$2" "$3" ;;
    *) printf 'the program %s (process %s)' "$2" "$3" ;;
  esac
}
# other_containers: "NAME (IMAGE)" of the running containers the takeover leaves alone.
other_containers() {
  local id name image ports t k a
  while IFS=$'\t' read -r id name image ports; do
    [[ -n $name && $name != tend-* ]] || continue
    for t in "${TAKEOVER[@]}"; do
      IFS=$'\t' read -r k a _ <<< "$t"
      if [[ $k == container && $a == "$name" ]]; then continue 2; fi
    done
    printf '%s (%s)\n' "$name" "$image"
  done < <(docker_ps_table)
}

# check_ports: in preflight. Free ports (or Tend's own proxy) pass; a web proxy is
# queued in TAKEOVER (stopped later, by take_over_ports, once the stack is written);
# anything else is refused in plain words.
check_ports() {
  local port o kind a b c line txt t seen k2 a2 oc n ans
  local -a rows=()
  TAKEOVER=()
  for port in 80 443; do
    o="$(port_owner "$port")"
    IFS=$'\t' read -r kind a b c <<< "$o"
    case $kind in none | tend) continue ;; esac
    rows+=("$port"$'\t'"$o")
  done
  if ((${#rows[@]} == 0)); then c_ok "Ports 80 and 443 are free"; return 0; fi
  for line in "${rows[@]}"; do
    IFS=$'\t' read -r port kind a b c <<< "$line"
    c_warn "Port $port: $(owner_text "$kind" "$a" "$b")"
  done
  if a="$(other_panel)"; then
    die "This server runs $a, another hosting panel. Two panels cannot share ports 80 and 443. Start from a fresh server: use Rebuild in your provider's console (Debian 12 or Ubuntu 24.04), then run the installer again."
  fi
  for line in "${rows[@]}"; do
    IFS=$'\t' read -r port kind a b c <<< "$line"
    txt="$(owner_text "$kind" "$a" "$b")"
    proxy_eligible "$kind" "$a" "$b" ||
      die "${txt^} uses port $port. Tend needs ports 80 and 443. Tend only stops a web proxy (nginx, Apache, Caddy, Traefik, HAProxy) for you; move this one yourself, or start from a fresh server with your provider's Rebuild."
    seen=0
    for t in "${TAKEOVER[@]}"; do
      IFS=$'\t' read -r k2 a2 _ <<< "$t"
      [[ $k2 == "$kind" && $a2 == "$a" ]] && seen=1
    done
    ((seen)) || TAKEOVER+=("$kind"$'\t'"$a"$'\t'"$b"$'\t'"$c")
  done
  if [[ ${TAKE_OVER_PORTS:-0} == 1 ]]; then
    for t in "${TAKEOVER[@]}"; do
      IFS=$'\t' read -r kind a b c <<< "$t"
      c_warn "$(owner_text "$kind" "$a" "$b") will be stopped (--take-over-ports), after Tend's files are written"
    done
    return 0
  fi
  if [[ ${ASSUME_YES:-0} == 1 ]] || ! tty_ok; then
    IFS=$'\t' read -r port kind a b c <<< "${rows[0]}"
    die "$(owner_text "$kind" "$a" "$b") uses port $port. Tend can stop it for you, but it needs your OK. Run the installer in a terminal to be guided, or add --take-over-ports to stop it without asking."
  fi
  echo
  echo "    Tend can stop this web proxy for you."
  echo "    Nothing is deleted: no container, file, setting or volume."
  echo
  echo "    Will be stopped and kept from starting at boot:"
  for t in "${TAKEOVER[@]}"; do
    IFS=$'\t' read -r kind a b c <<< "$t"
    echo "      - $(owner_text "$kind" "$a" "$b")"
  done
  echo "    Keep running, untouched:"
  oc="$(other_containers)"
  if [[ -n $oc ]]; then while IFS= read -r line; do echo "      - container $line"; done <<< "$oc"
  else echo "      (nothing else is running)"; fi
  echo
  echo "    Websites the old proxy served go offline"
  echo "    until you add their domains in Tend."
  n=0; [[ -z $oc ]] || n="$(wc -l <<< "$oc")"
  ((n <= 5)) || { echo "    This server already runs many things."; echo "    A fresh server is often simpler: your provider's Rebuild."; }
  printf '\n    Type yes to stop it, anything else to cancel: ' 2> /dev/null > /dev/tty || true
  ans="$(tty_line)"
  [[ $ans == yes ]] || die "Nothing was changed."
}

stop_failed() { # stop_failed NAME FILE
  local m="Could not stop $1."
  [[ ! -f $2 ]] || m+=" Whatever Tend already stopped can be started again with the commands in $2."
  die "$m"
}
# take_over_ports: right before start_stack. Stops (never removes) what check_ports
# queued, saves and prints the way back, then waits for the ports.
take_over_ports() {
  ((${#TAKEOVER[@]} > 0)) || return 0
  local file="$INSTALL_DIR/ports-taken-over.txt" t kind a b c pol rc undo txt i busy still
  c_step "Making room on ports 80 and 443"
  mkdir -p "$INSTALL_DIR"
  for t in "${TAKEOVER[@]}"; do
    IFS=$'\t' read -r kind a b c <<< "$t"
    txt="$(owner_text "$kind" "$a" "$b")"
    if [[ $kind == service ]]; then
      systemctl disable --now "$a" || stop_failed "$a" "$file"
      undo="sudo systemctl enable --now $a"
    else
      pol="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c" 2> /dev/null || true)"
      [[ -n $pol ]] || pol=no
      if [[ $pol == on-failure ]]; then
        rc="$(docker inspect -f '{{.HostConfig.RestartPolicy.MaximumRetryCount}}' "$c" 2> /dev/null || true)"
        [[ ! $rc =~ ^[1-9][0-9]*$ ]] || pol+=":$rc"
      fi
      docker update --restart=no "$c" > /dev/null || stop_failed "$a" "$file"
      docker stop "$c" > /dev/null || stop_failed "$a" "$file"
      undo="sudo docker stop tend-caddy && sudo docker update --restart=$pol $a && sudo docker start $a"
    fi
    c_warn "Stopped ${txt}. To undo:"
    printf '        %s\n' "$undo"
    printf '# %s  Tend stopped %s\n%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$txt" "$undo" >> "$file"
    chmod 0644 "$file"
    record "Stopped $txt (undo: $file)"
  done
  busy=1
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [[ "$(port_owner 80)" == none && "$(port_owner 443)" == none ]]; then busy=0; break; fi
    sleep 1
  done
  ((!busy)) || die "Ports 80 and 443 are still in use after stopping it. The way back is saved in $file."
  still="$(other_containers | wc -l)"
  c_ok "Ports 80 and 443 are free now. Still running, untouched: ${still// /} other container(s)."
}

# ---- steps ------------------------------------------------------------------

preflight() {
  c_step "Checking this machine"
  [[ $EUID -eq 0 ]] || die "This installer needs root. Run it with sudo."
  [[ -d /run/systemd/system ]] || die "This machine is not running systemd (a container?). Tend needs a full Linux server."
  if grep -qi microsoft /proc/version 2> /dev/null; then die "This is WSL. Use the Tend Windows installer instead."; fi
  [[ -f /etc/os-release ]] || die "Cannot tell which Linux this is (/etc/os-release is missing)."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "$(os_support "${ID:-}" "${VERSION_ID:-}")" in
    tier1) c_ok "$PRETTY_NAME is fully supported" ;;
    tier2) c_warn "$PRETTY_NAME works but is tested less often than Debian 12/13 and Ubuntu 22.04/24.04" ;;
    *) die "Unsupported system: ${PRETTY_NAME:-unknown}. Supported: Debian 12/13, Ubuntu 22.04/24.04 (also Rocky/Alma 9, Fedora)." ;;
  esac
  case "${ID:-}" in debian | ubuntu) OS_FAMILY=debian ;; *) OS_FAMILY=rhel ;; esac
  local kb disk
  kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  case "$(mem_verdict "$kb")" in
    refuse) die "Tend needs at least 1 GB of memory; this machine has $((kb / 1024)) MB." ;;
    warn) c_warn "$((kb / 1024)) MB of memory is enough to start, but 2 GB is comfortable for apps" ;;
    *) c_ok "Memory: $((kb / 1024)) MB" ;;
  esac
  disk="$(df -Pk "$([[ -d /var/lib/docker ]] && echo /var/lib/docker || echo /var/lib)" | awk 'NR==2 {print $4}')"
  disk_ok "$disk" || die "Tend needs 10 GB of free disk; this machine has $((disk / 1048576)) GB free."
  c_ok "Disk: $((disk / 1048576)) GB free"
  check_ports
  local code
  code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' https://ghcr.io/v2/ 2> /dev/null || true)"
  [[ $code != 000 ]] || die "Cannot reach ghcr.io (where the Tend image is stored). Check this machine's internet and firewall."
  c_ok "Can reach the image registry"
}

choose_profile() {
  local override="$LOCAL_MODE" has_domain=0 pub_if=0 meta=0 suggest answer
  [[ -z $DOMAIN ]] || has_domain=1
  if [[ -z $override ]]; then
    if [[ -n $(ip -o -4 addr show scope global 2> /dev/null | interface_addrs public) ]]; then pub_if=1; fi
    if meta_answers; then meta=1; CLOUD=1; fi
  fi
  suggest="$(resolve_profile "$override" "$has_domain" "$pub_if" "$meta")"
  PROFILE="$suggest"
  if [[ -z $override && $has_domain == 0 ]]; then
    if [[ $suggest == home ]]; then
      ask "This looks like a home server (opened from devices on your own network). Is that right?" Y || PROFILE=vps
    else
      ask "This looks like a server on the internet. Is that right?" Y || PROFILE=home
    fi
  fi
  if [[ $PROFILE == home ]]; then
    if [[ $LOCAL_NAME_GIVEN != 1 && $ASSUME_YES != 1 ]] && tty_ok; then
      printf '    Name on your network [%s] (opens as https://<name>.local): ' "$LOCAL_NAME" > /dev/tty
      read -r answer < /dev/tty || answer=""
      [[ -z $answer ]] || LOCAL_NAME="$answer"
    fi
    LOCAL_NAME="$(normalize_local_name "$LOCAL_NAME")" ||
      die "The local name must be one word of letters, digits and dashes (for example: tend, mynas)."
    c_ok "Home server: Tend will answer at ${LOCAL_NAME}.local and by this machine's address"
  else
    c_ok "Server on the internet"
  fi
}

update_system() {
  [[ $SKIP_SYSTEM_UPDATE != 1 ]] || { c_step "Skipping system updates (SKIP_SYSTEM_UPDATE=1)"; return 0; }
  c_step "Installing security updates"
  if [[ $OS_FAMILY == debian ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq > /dev/null
    apt-get -y -qq -o Dpkg::Use-Pty=0 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade > /dev/null
  else dnf upgrade -y -q > /dev/null; fi
  c_ok "System packages are current"; record "System packages upgraded"
}

install_base_packages() {
  c_step "Installing base tools"
  if [[ $OS_FAMILY == debian ]]; then
    apt_install ca-certificates curl gnupg jq iproute2 chrony openssl
    apt_install qrencode > /dev/null 2>&1 || true
  else
    dnf_install ca-certificates curl gnupg2 jq iproute chrony openssl
    dnf_install qrencode > /dev/null 2>&1 || true
  fi
  systemctl enable --now chrony.service 2> /dev/null || systemctl enable --now chronyd.service 2> /dev/null || true
  c_ok "Base tools are in place"
}

harden_vps() {
  [[ $SKIP_HARDENING != 1 ]] || { c_step "Skipping hardening (SKIP_HARDENING=1)"; return 0; }
  c_step "Hardening this server"
  local ssh_port
  ssh_port="$(ss -tlpn 2> /dev/null | awk '/sshd/ {gsub(".*:","",$4); print $4; exit}')"; ssh_port="${ssh_port:-22}"
  if [[ $OS_FAMILY == debian ]]; then
    apt_install unattended-upgrades apt-listchanges fail2ban ufw
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\nUnattended-Upgrade::Automatic-Reboot "true";\nUnattended-Upgrade::Automatic-Reboot-Time "03:00";\n' \
      > /etc/apt/apt.conf.d/52tend-host-unattended
    systemctl enable --now unattended-upgrades.service 2> /dev/null || true
  else
    dnf_install dnf-automatic epel-release || true
    dnf_install fail2ban firewalld || true
    sed -i 's/^apply_updates =.*/apply_updates = yes/' /etc/dnf/automatic.conf
    systemctl enable --now dnf-automatic.timer
  fi
  record "Unattended security upgrades (auto-reboot 03:00 if the kernel changes)"
  printf '[DEFAULT]\nbantime = 1h\nfindtime = 10m\nmaxretry = 5\nignoreip = 127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16\n\n[sshd]\nenabled = true\n' > /etc/fail2ban/jail.local
  systemctl enable --now fail2ban; systemctl restart fail2ban
  record "fail2ban on SSH (5 failures in 10 minutes bans for 1 hour)"
  if [[ $OS_FAMILY == debian ]]; then
    if ! ufw status 2> /dev/null | grep -q '^Status: active'; then ufw default deny incoming > /dev/null; ufw default allow outgoing > /dev/null; fi
    ufw allow "${ssh_port}/tcp" comment 'SSH' > /dev/null
    ufw allow 80/tcp comment 'Tend HTTP' > /dev/null; ufw allow 443/tcp comment 'Tend HTTPS' > /dev/null; ufw allow 443/udp comment 'Tend HTTP/3' > /dev/null
    ufw --force enable > /dev/null
  else
    systemctl enable --now firewalld
    firewall-cmd --permanent --add-port="${ssh_port}/tcp" --add-service=http --add-service=https > /dev/null
    firewall-cmd --permanent --add-port=443/udp > /dev/null; firewall-cmd --reload > /dev/null
  fi
  c_ok "Firewall on: SSH ($ssh_port), 80 and 443 open; everything else closed"
  record "Firewall: SSH ${ssh_port}, 80, 443 only (Tend's own port 8787 is not published at all)"
}

# ---- SSH: offer to turn password logins off ------------------------------------
# Changed only after a key sign-in is proven, only when the person types yes (or
# passes --ssh-keys-only), and put back unless `sshd -t` passes and `sshd -T`
# confirms the result. The paths can be pointed elsewhere for the tests.

SSHD_CONFIG="${SSHD_CONFIG:-/etc/ssh/sshd_config}"
SSHD_DROPIN_DIR="${SSHD_DROPIN_DIR:-/etc/ssh/sshd_config.d}"
SSHD_DROPIN_NAME="00-tend-keys-only.conf"
SSHD_RUN_DIR="${SSHD_RUN_DIR:-/run/sshd}"
PASSWD_FILE="${PASSWD_FILE:-/etc/passwd}"
SHADOW_FILE="${SHADOW_FILE:-/etc/shadow}"
SSH_MARK_BEGIN="# BEGIN tend keys-only (added by the Tend installer)"
SSH_MARK_END="# END tend keys-only"
SSH_KEY_TYPES='ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com'

sshd_bin() { command -v sshd 2> /dev/null || { [[ -x /usr/sbin/sshd ]] && echo /usr/sbin/sshd; } || true; }
# sshd_value KEY: the effective setting from `sshd -T` (key in lower case), empty when unknown.
sshd_value() { local b; b="$(sshd_bin)"; [[ -n $b ]] || return 0; "$b" -T 2> /dev/null | awk -v k="$1" '$1 == k {print $2; exit}' || true; }
# ssh_kbd_key: the keyboard-interactive keyword this sshd knows (old ones only know the ChallengeResponse name).
ssh_kbd_key() { if [[ -n "$(sshd_value kbdinteractiveauthentication)" || -z "$(sshd_value challengeresponseauthentication)" ]]; then echo kbdinteractiveauthentication; else echo challengeresponseauthentication; fi; }

# valid_key_line LINE: an authorized_keys line that carries a public key (comments, blanks and junk do not).
valid_key_line() {
  local l="${1#"${1%%[![:space:]]*}"}" re="(^|[[:space:]])(${SSH_KEY_TYPES})[[:space:]]+[A-Za-z0-9+/]{16,}={0,3}([[:space:]]|\$)"
  [[ $l != \#* ]] && [[ $l =~ $re ]]
}
# count_keys FILE: how many valid key lines the file holds (0 if it is missing or unreadable).
count_keys() {
  local n=0 l
  [[ -r $1 ]] || { echo 0; return 0; }
  while IFS= read -r l || [[ -n $l ]]; do if valid_key_line "$l"; then n=$((n + 1)); fi; done < "$1"
  echo "$n"
}
# user_key_count USER: valid keys in that account's ~/.ssh/authorized_keys.
user_key_count() { local h; h="$(getent passwd "$1" 2> /dev/null | cut -d: -f6)" || h=""; if [[ -n $h ]]; then count_keys "$h/.ssh/authorized_keys"; else echo 0; fi; }
# password_account_count: login accounts that hold a usable password hash. Only the count is ever shown.
password_account_count() {
  [[ -r $SHADOW_FILE && -r $PASSWD_FILE ]] || { echo 0; return 0; }
  awk -F: 'NR == FNR { if ($7 != "" && $7 !~ /(nologin|false)$/) ok[$1] = 1; next } ($1 in ok) && $2 ~ /^\$/ { n++ } END { print n + 0 }' "$PASSWD_FILE" "$SHADOW_FILE"
}
# session_client_ip: the address this SSH session came from ($SSH_CONNECTION; sudo drops it, so the
# parent processes' environment is searched too). Empty when this is not an SSH session.
session_client_ip() {
  local c="${SSH_CONNECTION:-}" pid="$$" i f
  if [[ -z $c ]]; then
    for ((i = 0; i < 25; i++)); do
      f="${PROC_ROOT:-/proc}/$pid/environ"
      if [[ -r $f ]]; then c="$(tr '\0' '\n' < "$f" 2> /dev/null | sed -n 's/^SSH_CONNECTION=//p' | head -1)" || c=""; [[ -z $c ]] || break; fi
      pid="$(awk '/^PPid:/ {print $2}' "${PROC_ROOT:-/proc}/$pid/status" 2> /dev/null)" || pid=""
      if [[ ! $pid =~ ^[0-9]+$ ]] || ((pid <= 1)); then break; fi
    done
  fi
  printf '%s' "${c%% *}"
}
# journal_has_publickey USER IP: sshd logged a key sign-in for USER from IP in the last hour.
journal_has_publickey() {
  local out
  [[ -n $1 && -n $2 ]] || return 1
  out="$(journalctl -u ssh -u sshd --since '1 hour ago' --no-pager -q -o cat 2> /dev/null)" || out=""
  [[ $out == *"Accepted publickey for $1 from $2 port"* ]]
}
ssh_reload() { systemctl reload ssh 2> /dev/null || systemctl reload sshd 2> /dev/null; }
# ssh_undo MODE FILE BACKUP: put the SSH configuration back as it was before ssh_apply_keys_only.
ssh_undo() {
  if [[ $1 == dropin ]]; then if [[ -n $3 ]]; then cat "$3" > "$2"; else rm -f "$2"; fi
  elif [[ -f $SSHD_CONFIG.tend-bak ]]; then cat "$SSHD_CONFIG.tend-bak" > "$SSHD_CONFIG"; fi
}

# ssh_apply_keys_only: write the setting, check it, reload, verify. Returns 1 (everything put back)
# when a check fails, and says why. The running session is never restarted, only reloaded.
ssh_apply_keys_only() {
  local conf="$SSHD_CONFIG" file="$SSHD_DROPIN_DIR/$SSHD_DROPIN_NAME" mode bak="" kbdkey kbdword block why="" tmp
  kbdkey="$(ssh_kbd_key)"
  if [[ $kbdkey == kbdinteractiveauthentication ]]; then kbdword=KbdInteractiveAuthentication; else kbdword=ChallengeResponseAuthentication; fi
  block="PasswordAuthentication no"$'\n'"$kbdword no"
  [[ -d $SSHD_RUN_DIR ]] || mkdir -p "$SSHD_RUN_DIR" 2> /dev/null || true
  tmp="$(mktemp)"
  if grep -Eiq '^[[:space:]]*Include[[:space:]]+(/etc/ssh/)?sshd_config\.d/\*\.conf' "$conf" 2> /dev/null; then
    mode=dropin
    if [[ -f $file ]]; then bak="$(mktemp)"; cp -p "$file" "$bak"; fi
    mkdir -p "$SSHD_DROPIN_DIR"
    printf '# Written by the Tend installer. Delete this file and reload ssh to allow SSH passwords again.\n%s\n' "$block" > "$file"
    chmod 0644 "$file"
  else
    # No drop-in directory: the first value wins in sshd_config, so the block goes at the very top.
    mode=main
    if ! grep -qF "$SSH_MARK_BEGIN" "$conf" 2> /dev/null; then
      cp -p "$conf" "$conf.tend-bak"
      { printf '%s\n%s\n%s\n\n' "$SSH_MARK_BEGIN" "$block" "$SSH_MARK_END"; cat "$conf"; } > "$tmp"
      cat "$tmp" > "$conf"
    fi
  fi
  rm -f "$tmp"
  if ! "$(sshd_bin)" -t 2> /dev/null; then why="the SSH configuration check (sshd -t) failed"
  elif ! ssh_reload; then why="the SSH service would not reload"
  elif [[ "$(sshd_value passwordauthentication)" != no || "$(sshd_value "$kbdkey")" == yes ]]; then why="SSH would still accept passwords because an earlier setting wins"
  fi
  if [[ -n $why ]]; then
    ssh_undo "$mode" "$file" "$bak"; ssh_reload || true
    [[ -z $bak ]] || rm -f "$bak"
    c_warn "Password logins were left on: $why. Nothing was changed."
    return 1
  fi
  [[ -z $bak ]] || rm -f "$bak"
  if [[ $mode == dropin ]]; then SSH_FILE="$file"; else SSH_FILE="$conf"; fi
  return 0
}

# ssh_keys_only_step: runs after hardening. Sets SSH_STATE for the final screen:
#   off (keys only), offer (key login proven, password logins left on), nokey (key login not proven),
#   kept (--keep-ssh-passwords). Never stops the install.
ssh_keys_only_step() {
  [[ ${SKIP_HARDENING:-0} != 1 ]] || return 0
  [[ -n "$(sshd_bin)" ]] || return 0
  local pw kbd user ip n_keys n_acc ans undo_text
  SSH_STATE=""
  c_step "Checking how people sign in over SSH"
  pw="$(sshd_value passwordauthentication)"; kbd="$(sshd_value "$(ssh_kbd_key)")"
  if [[ -z $pw ]]; then c_ok "Could not read the SSH settings, so they were left alone"; return 0; fi
  if [[ $pw == no && $kbd != yes ]]; then SSH_STATE=off; c_ok "SSH already refuses passwords (keys only)"; return 0; fi
  if [[ ${KEEP_SSH_PASSWORDS:-0} == 1 ]]; then SSH_STATE=kept; c_ok "SSH password logins left on (--keep-ssh-passwords)"; return 0; fi
  user="${SUDO_USER:-root}"; ip="$(session_client_ip)"
  n_keys="$(user_key_count "$user")"
  if ((n_keys == 0)) || ! journal_has_publickey "$user" "$ip"; then
    SSH_STATE=nokey
    c_warn "SSH accepts passwords, and a key sign-in could not be confirmed, so nothing was changed."
    return 0
  fi
  n_acc="$(password_account_count)"
  if [[ ${SSH_KEYS_ONLY:-0} != 1 ]]; then
    if [[ ${ASSUME_YES:-0} == 1 ]] || ! tty_ok; then
      SSH_STATE=offer; c_warn "SSH password logins stay on. Run the installer again with --ssh-keys-only to turn them off."
      return 0
    fi
    echo
    echo "    Your server lets anyone try passwords over SSH."
    echo "    You signed in with a key, so we can turn password"
    echo "    logins off. Scanners then can't even try."
    if ((n_acc > 0)); then
      echo "    ($n_acc account(s) here have a password. It keeps working"
      echo "    on the console; only SSH stops accepting it.)"
    fi
    printf '\n    Turn password logins off? Type yes to do it, or press Enter to skip: ' 2> /dev/null > /dev/tty || true
    ans="$(tty_line)"
    if [[ $ans != yes ]]; then SSH_STATE=offer; c_ok "Skipped. SSH password logins stay on."; return 0; fi
  fi
  if ssh_apply_keys_only; then
    SSH_STATE=off
    if [[ $SSH_FILE == "$SSHD_CONFIG" ]]; then undo_text="restore $SSHD_CONFIG.tend-bak, then: sudo systemctl reload ssh"
    else undo_text="sudo rm $SSH_FILE && sudo systemctl reload ssh"; fi
    c_ok "SSH password logins are off. Your key still works."
    echo "        To undo: $undo_text"
    record "SSH: keys only, password logins off (undo: $undo_text)"
  else
    SSH_STATE=offer
  fi
  return 0
}
# ssh_row_lines: the SSH line(s) for the boxed end screen (each at most 54 characters).
ssh_row_lines() {
  case "${SSH_STATE:-}" in
    off) echo "SSH: keys only (password logins off)" ;;
    offer) echo "SSH: password logins are on. To turn them off,"; echo "run the installer again with --ssh-keys-only." ;;
    nokey) echo "SSH: password logins are on. Add an SSH key,"; echo "then run the installer with --ssh-keys-only." ;;
    kept) echo "SSH: password logins left on, as you asked." ;;
  esac
}

# harden_home: a home box often runs other services (a NAS), so ufw is turned
# on only when nothing else listens. The web ports are limited in DOCKER-USER.
harden_home() {
  c_step "Protecting this home server"
  local other
  other="$(ss -ltnH 2> /dev/null | awk '{print $4}' | grep -Ev '^(127\.|\[::1\]|\[::\]:22$|0\.0\.0\.0:22$|\*:22$|\[::ffff:127\.)' | head -3 || true)"
  if [[ $OS_FAMILY == debian && $SKIP_HARDENING != 1 ]]; then
    apt_install ufw > /dev/null
    if ufw status 2> /dev/null | grep -q '^Status: active'; then
      for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do ufw allow from "$net" to any port 5353 proto udp comment 'Tend mDNS' > /dev/null; done
      c_ok "ufw was already on: added the home-network name announcer rule only"
    elif [[ -n $other ]]; then
      c_warn "Other services on this machine listen on the network, so ufw was left off to avoid cutting them."
    else
      ssh_port="$(ss -tlpn 2> /dev/null | awk '/sshd/ {gsub(".*:","",$4); print $4; exit}')"
      ufw default deny incoming > /dev/null; ufw default allow outgoing > /dev/null; ufw allow "${ssh_port:-22}/tcp" comment 'SSH' > /dev/null
      for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do ufw allow from "$net" to any port 5353 proto udp comment 'Tend mDNS' > /dev/null; done
      ufw --force enable > /dev/null
      c_ok "ufw on: SSH and the name announcer from the home network only"; record "ufw: SSH, mDNS from the home network"
    fi
  fi
}

install_lan_firewall() {
  if ! command -v iptables > /dev/null 2>&1; then
    if [[ $OS_FAMILY == debian ]]; then apt_install iptables 2> /dev/null || true; else dnf_install iptables-nft > /dev/null 2>&1 || true; fi
  fi
  command -v iptables > /dev/null 2>&1 || die "iptables is missing, so Tend cannot limit its web ports to your home network. Install iptables and run this again."
  mkdir -p "$LIB_DIR"
  render_lan_firewall > "$LIB_DIR/lan-firewall.sh"; chmod 0755 "$LIB_DIR/lan-firewall.sh"
  render_lan_firewall_unit > "/etc/systemd/system/$FIREWALL_UNIT"
  systemctl daemon-reload
  systemctl enable "$FIREWALL_UNIT" > /dev/null 2>&1
  "$LIB_DIR/lan-firewall.sh" apply
  record "Web ports 80/443 answer only the home network (DOCKER-USER rule, restored at boot by $FIREWALL_UNIT)"
}

# drop_home_leftovers: a host switched from home to public loses the LAN-only rule and the announcer.
drop_home_leftovers() {
  [[ -x $LIB_DIR/lan-firewall.sh ]] || return 0
  "$LIB_DIR/lan-firewall.sh" remove || true
  systemctl disable --now "$FIREWALL_UNIT" > /dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$FIREWALL_UNIT" "$LIB_DIR/lan-firewall.sh"; rmdir "$LIB_DIR" 2> /dev/null || true
  docker rm -f tend-mdns > /dev/null 2>&1 || true
}

# docker_firewall_problem DAEMON_JSON SECURITY_OPTIONS: prints a sentence when
# Docker cannot be trusted to keep the control network private, nothing when it
# can. Rootless Docker and "iptables": false both leave Docker without its
# firewall rules, so the isolation the fixed control addresses rely on (G11:
# only the proxy reaches the panel) does not hold and every published port is
# the host's own business.
docker_firewall_problem() {
  if [[ $2 == *rootless* ]]; then
    printf 'Docker here runs rootless, which has no firewall rules of its own, so Tend cannot keep its internal network private.'
  elif [[ -f $1 ]] && grep -Eq '"iptables"[[:space:]]*:[[:space:]]*false' "$1"; then
    printf 'Docker here is set to "iptables": false, so it adds no firewall rules and Tend cannot keep its internal network private.'
  fi
}

install_docker() {
  c_step "Checking Docker"
  if command -v docker > /dev/null 2>&1 && docker compose version > /dev/null 2>&1; then
    if [[ $USE_EXISTING_DOCKER != 1 ]] && { command -v snap > /dev/null 2>&1 && snap list docker > /dev/null 2>&1 || dpkg -s docker.io > /dev/null 2>&1 || docker --version 2> /dev/null | grep -qi podman; }; then
      die "Docker here comes from snap, docker.io or podman, which Tend does not manage. Run again with --use-existing-docker to keep it, or remove it first."
    fi
    c_ok "Docker is installed: $(docker --version | head -1)"
    local problem
    problem="$(docker_firewall_problem /etc/docker/daemon.json "$(docker info --format '{{.SecurityOptions}}' 2> /dev/null || true)")"
    [[ -z $problem ]] || c_warn "$problem Tend still installs, but the panel may be reachable from other containers. Use the standard Docker Engine (iptables on, not rootless) when you can."
    return 0
  fi
  c_step "Installing Docker Engine"
  if [[ $OS_FAMILY == debian ]]; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -qq > /dev/null
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    dnf_install dnf-plugins-core
    dnf config-manager --add-repo "https://download.docker.com/linux/$([[ ${ID} == fedora ]] && echo fedora || echo centos)/docker-ce.repo"
    dnf_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  systemctl enable --now docker
  c_ok "Docker installed: $(docker --version | head -1)"
}

# The panel's own updater and this installer both rewrite .env and the compose
# project, so they share one lock: the directory the updater already creates in
# the data directory. A lock older than two hours is left over from a killed run.
UPDATE_LOCK_HELD=0
take_update_lock() {
  local lock="$DATA_DIR/self-update/apply.lock"
  mkdir -p "$DATA_DIR/self-update"
  if ! mkdir "$lock" 2> /dev/null; then
    if [[ -n $(find "$lock" -maxdepth 0 -mmin +120 2> /dev/null) ]]; then
      rmdir "$lock" 2> /dev/null || true
      mkdir "$lock" 2> /dev/null || die "A panel update is running. Wait for it to finish, then run this again."
    else
      die "A panel update is running. Wait for it to finish, then run this again."
    fi
  fi
  UPDATE_LOCK_HELD=1
}
release_update_lock() {
  [[ $UPDATE_LOCK_HELD != 1 ]] || rmdir "$DATA_DIR/self-update/apply.lock" 2> /dev/null || true
  UPDATE_LOCK_HELD=0
}
cleanup_on_exit() {
  release_update_lock
  [[ -z ${TEND_STAGE_DIR:-} ]] || rm -rf "$TEND_STAGE_DIR"
}

write_stack() {
  c_step "Writing the Tend stack to $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR" "$DATA_DIR/localnet"; chmod 0755 "$DATA_DIR"
  if [[ -f $INSTALL_DIR/docker-compose.yml ]]; then
    cp -f "$INSTALL_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml.prev"
    [[ ! -f $INSTALL_DIR/.env ]] || cp -f "$INSTALL_DIR/.env" "$INSTALL_DIR/.env.prev"
  fi
  render_compose > "$INSTALL_DIR/docker-compose.yml"
  render_env "$IMAGE_REF" "$PROFILE" "$PANEL_FQDN" "$PUBLIC_IP" "$LOCAL_NAME" > "$INSTALL_DIR/.env"
  local caddyfile
  if [[ $PROFILE == vps ]]; then caddyfile="$(render_caddyfile vps "$PANEL_FQDN" "$PUBLIC_IP" "$DOMAIN_EMAIL")"
  else caddyfile="$(render_caddyfile home "${LOCAL_NAME}.local" "$LAN_IPS" "")"; fi
  # Caddy only reads its file at start: note a change so start_stack restarts a running proxy.
  CADDY_CHANGED=0
  [[ -f $INSTALL_DIR/Caddyfile && "$(< "$INSTALL_DIR/Caddyfile")" == "$caddyfile" ]] || CADDY_CHANGED=1
  printf '%s\n' "$caddyfile" > "$INSTALL_DIR/Caddyfile"
  docker network inspect tend-net > /dev/null 2>&1 || docker network create tend-net > /dev/null
  c_ok "docker-compose.yml, .env and Caddyfile written"
}

start_stack() {
  c_step "Starting Tend ${TEND_M_VERSION}"
  cd "$INSTALL_DIR"
  if docker image inspect "$IMAGE_REF" > /dev/null 2>&1; then c_ok "The image is already on this machine"
  else docker compose pull --quiet || die "Could not pull the Tend image ($IMAGE_REF)."; fi
  [[ -z ${TEND_SETUP_CODE:-} ]] || export TEND_SETUP_CODE
  local caddy_was_running=0
  [[ -z $(docker ps -q -f name=tend-caddy 2> /dev/null) ]] || caddy_was_running=1
  docker compose up -d --remove-orphans
  if [[ $caddy_was_running == 1 && ${CADDY_CHANGED:-0} == 1 ]]; then docker restart tend-caddy > /dev/null; fi
  c_ok "Containers started"
}

wait_for() { # wait_for SECONDS COMMAND...
  local deadline=$(($(date +%s) + $1)); shift
  while (($(date +%s) < deadline)); do "$@" > /dev/null 2>&1 && return 0; sleep 3; printf '.'; done
  return 1
}
panel_healthy() { docker exec tend-host curl -fsS http://127.0.0.1:8787/healthz; }
https_up() { curl -fsS -m 5 --resolve "$PANEL_FQDN:443:127.0.0.1" "https://$PANEL_FQDN/healthz"; }

rollback() {
  c_err "The new version did not start. Going back to the previous one."
  if ((${#TAKEOVER[@]} > 0)); then c_warn "The web proxy Tend stopped is still stopped. To start it again, use the commands in $INSTALL_DIR/ports-taken-over.txt"; fi
  if [[ -f $INSTALL_DIR/docker-compose.yml.prev ]]; then
    cp -f "$INSTALL_DIR/docker-compose.yml.prev" "$INSTALL_DIR/docker-compose.yml"
    [[ ! -f $INSTALL_DIR/.env.prev ]] || cp -f "$INSTALL_DIR/.env.prev" "$INSTALL_DIR/.env"
    (cd "$INSTALL_DIR" && docker compose up -d --remove-orphans) || true
  fi
}

# http_head HOSTHEADER URL: status code and Location of one plain request to the local proxy.
http_head() {
  curl -s -o /dev/null -m 5 -D - -H "Host: $1" "$2" 2> /dev/null | tr -d '\r' |
    awk 'NR == 1 {code = $2} tolower($1) == "location:" {loc = $2} END {printf "%s %s", code, loc}'
}
# The panel publishes the IP routes through the proxy's admin API shortly after
# it starts; these wait for them.
public_ip_redirects() { [[ "$(http_head "$PUBLIC_IP" http://127.0.0.1/)" == "308 https://$PANEL_FQDN/" ]]; }
lan_ip_answers() { [[ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://${LAN_IP}/healthz" 2> /dev/null)" == 200 ]]; }

verify_addresses() {
  c_step "Checking the addresses"
  if [[ $PROFILE == vps ]]; then
    if wait_for 120 https_up; then echo; c_ok "https://$PANEL_FQDN answers with a valid certificate"
    else
      echo; c_warn "https://$PANEL_FQDN has no certificate yet."
      c_warn "Usual causes: ports 80 and 443 are blocked by the hosting provider's firewall, or the name has not reached DNS."
      c_warn "Last Caddy message: $(docker logs tend-caddy 2>&1 | sed -n 's/.*"error":"\([^"]*\)".*/\1/p' | tail -1 | cut -c1-200)"
    fi
    if wait_for 60 public_ip_redirects; then echo; c_ok "http://$PUBLIC_IP sends visitors to the https address"
    else echo; c_warn "http://$PUBLIC_IP answered '$(http_head "$PUBLIC_IP" http://127.0.0.1/)', expected a 308 to https://$PANEL_FQDN/ (the panel adds it within a few minutes)"; fi
  else
    if wait_for 60 lan_ip_answers; then echo; c_ok "http://$LAN_IP answers"
    else echo; c_warn "http://$LAN_IP did not answer; check: docker logs tend-caddy"; fi
  fi
}

# read_setup_code: finds the code to show. When the image carries the engine's
# own command it is asked first, and its exit status is read: 0 the code is on
# stdout, 3 an administrator exists, 4 the code came from TEND_SETUP_CODE (it is
# not stored), 5 setup codes are off; anything else falls back to the code file.
read_setup_code() {
  SETUP_CODE=""; ADMIN_EXISTS=0; SETUP_NOTE=""
  if docker exec tend-host curl -fsS http://127.0.0.1:8787/api/auth/setup-status 2> /dev/null | grep -q '"first_run":[[:space:]]*false'; then ADMIN_EXISTS=1; return 0; fi
  [[ -z ${TEND_SETUP_CODE:-} ]] || { SETUP_CODE="$(format_code "$TEND_SETUP_CODE")"; return 0; }
  local _ out="" rc code
  if docker exec tend-host test -e /usr/local/share/tend/cli-v1 > /dev/null 2>&1; then
    out="$(docker exec tend-host tend setup-code 2> /dev/null)"; rc=$?
    case $rc in
      0) code="$(sed -n 's/^Setup code: //p' <<< "$out" | head -1)"; [[ -z $code ]] || { SETUP_CODE="$(format_code "$code")"; return 0; } ;;
      3) ADMIN_EXISTS=1; return 0 ;;
      4) SETUP_NOTE="The setup code is the one given as TEND_SETUP_CODE when Tend was installed; Tend does not keep it."; return 0 ;;
      5) SETUP_NOTE="Setup codes are turned off on this panel."; return 0 ;;
    esac
  fi
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -s $DATA_DIR/first-run-setup-code ]] && { SETUP_CODE="$(format_code "$(< "$DATA_DIR/first-run-setup-code")")"; return 0; }
    sleep 1
  done
}

# The address to show for a VPS: the panel's current one when the installed
# engine can say (the admin may have moved it), else the one this run knows.
panel_host_now() {
  local cur=""
  if docker exec tend-host test -e /usr/local/share/tend/cli-v1 > /dev/null 2>&1; then
    cur="$(docker exec tend-host tend address --current 2> /dev/null | head -1 | tr -d '[:space:]')" || cur=""
  fi
  [[ $cur =~ ^[a-z0-9.-]+$ ]] || cur=""
  printf '%s' "${cur:-$PANEL_FQDN}"
}

addresses_text() {
  if [[ $PROFILE == home ]]; then
    printf '    https://%s.local   (a browser warning until the device trusts Tend: open /trust)\n' "$LOCAL_NAME"
    [[ -z $LAN_IP ]] || printf '    http://%s   (works on any phone, no name lookup needed)\n' "$LAN_IP"
  else
    printf '    https://%s\n' "$(panel_host_now)"
    [[ -z $PUBLIC_IP || $PUBLIC_IP == *:* ]] || printf '    or http://%s   (sends you to the address above)\n' "$PUBLIC_IP"
  fi
}

# panel_url: the address the final screen sends the user to.
panel_url() {
  if [[ $PROFILE == home ]]; then printf 'http://%s' "${LAN_IP:-${LOCAL_NAME}.local}"; else printf 'https://%s' "$(panel_host_now)"; fi
}

# final_box: the last thing the installer prints (the code or the way back is the
# last thing on screen). The wording is part of the product: plain words, numbered
# steps, nothing that scrolls away.
final_box() {
  local url="${1:-$(panel_url)}" words line n
  local -a nwords sshrows
  local -a rows=()
  mapfile -t sshrows < <(ssh_row_lines)
  echo
  if [[ ${ADMIN_EXISTS:-0} == 1 ]]; then
    rows=("" "Open:  $url" "Sign in with your account." "Forgot the password?  sudo tend reset-admin")
    if ((${#sshrows[@]} > 0)); then rows+=("" "${sshrows[@]}"); fi
    ui_box "Tend is ready." "${rows[@]}"
    return 0
  fi
  rows=("" "1. Open this address in a browser:" "     $url")
  if [[ -n ${SETUP_CODE:-} ]]; then
    rows+=("2. Type this setup code:  ${SETUP_CODE}"$'\t'"2. Type this setup code:  ${C_CODE}${SETUP_CODE}${C_OFF}" "3. Make your account. Keep this code until then.")
  elif [[ -n ${SETUP_NOTE:-} ]]; then
    # The note wraps at 50 characters on word boundaries, under the number.
    words=""; n=0
    read -r -a nwords <<< "$SETUP_NOTE"
    for line in "${nwords[@]}"; do
      if ((${#words} + ${#line} + 1 > 50)) && [[ -n $words ]]; then
        if ((n == 0)); then rows+=("2. $words"); else rows+=("   $words"); fi
        n=$((n + 1)); words="$line"
      else words="${words:+$words }$line"; fi
    done
    if ((n == 0)); then rows+=("2. $words"); else rows+=("   $words"); fi
    rows+=("3. Make your account.")
  else
    rows+=("2. Show the setup code:  sudo tend setup-code" "3. Make your account.")
  fi
  rows+=("" "Lost the code?  sudo tend setup-code" "Want your own address, like panel.example.com?" "Set it in Tend after you sign in.")
  if ((${#sshrows[@]} > 0)); then rows+=("" "${sshrows[@]}"); fi
  ui_box "Tend is ready. Finish in 3 steps:" "${rows[@]}"
}

# account_ready: has the first account been made? (the panel answers first_run false)
account_ready() {
  docker exec tend-host curl -fsS http://127.0.0.1:8787/api/auth/setup-status 2> /dev/null | grep -q '"first_run":[[:space:]]*false'
}

# wait_for_account: after the box, on a terminal only. Keeps the box on screen,
# says so when the account exists, and ends on Enter or after 30 minutes.
# Automation (--yes, no terminal) never waits.
wait_for_account() {
  [[ ${ASSUME_YES:-0} == 0 && -n ${SETUP_CODE:-} ]] && tty_ok || return 0
  release_update_lock
  printf '\nWaiting for you to make your account... (press Enter to stop waiting)\n'
  local deadline=$((SECONDS + 1800)) rc
  while ((SECONDS < deadline)); do
    if account_ready; then printf 'Done: your account is ready. You can close this window.\n'; return 0; fi
    rc=0; read -r -t 3 _ < /dev/tty || rc=$?
    ((rc > 128)) || return 0
  done
  return 0
}

# install_claim_banner: a login reminder that exists only while nobody has made
# the first account. It tests that the engine's code file exists and never reads
# it, so the code itself is never on disk outside that file.
install_claim_banner() {
  local motd_dir="${MOTD_DIR:-/etc/update-motd.d}" prof_dir="${PROFILE_D:-/etc/profile.d}" url file code_q
  url="$(panel_url)"
  printf -v code_q '%q' "$DATA_DIR/first-run-setup-code"
  rm -f "$motd_dir/60-tend" "$prof_dir/tend-claim.sh"
  [[ ${ADMIN_EXISTS:-0} != 1 ]] || return 0
  if [[ -d $motd_dir ]]; then
    file="$motd_dir/60-tend"
    {
      printf '#!/bin/sh\n# Generated by the Tend installer. Prints only while no account exists.\n'
      printf '[ -e %s ] || exit 0\n' "$code_q"
      printf 'echo "Tend is waiting for its first account."\n'
      printf 'echo "Open %s and type the setup code."\n' "$url"
      printf 'echo "Show the code: sudo tend setup-code"\n'
    } > "$file"
    chmod 0755 "$file"
  else
    mkdir -p "$prof_dir"
    file="$prof_dir/tend-claim.sh"
    {
      printf '# Generated by the Tend installer. Prints only while no account exists.\n'
      printf 'case $- in *i*) ;; *) return 0 ;; esac\n'
      printf '[ -e %s ] || return 0\n' "$code_q"
      printf 'echo "Tend is waiting for its first account."\n'
      printf 'echo "Open %s and type the setup code."\n' "$url"
      printf 'echo "Show the code: sudo tend setup-code"\n'
    } > "$file"
    chmod 0644 "$file"
  fi
}

# qr_ok: a QR code only on a terminal that can show it (a log file gets none).
qr_ok() { [[ -t 1 ]] && command -v qrencode > /dev/null 2>&1; }

summary() {
  local url qr
  url="$(panel_url)"
  echo
  if [[ ${#APPLIED[@]} -gt 0 ]]; then echo "  What was set up:"; printf '    - %s\n' "${APPLIED[@]}"; echo; fi
  if [[ $PROFILE == home ]]; then
    echo "  Tip: in your router, give this machine a fixed address,"
    echo "  so $LAN_IP does not change."
  elif [[ ${CLOUD:-0} == 1 ]]; then
    echo "  Your hosting provider has its own firewall."
    echo "  If the page does not open, allow ports 80 and 443 there."
  fi
  [[ ! -f /var/run/reboot-required ]] || echo "  A reboot is queued for system updates; do it when convenient."
  echo "  Other commands: sudo tend status | update | logs | addresses | uninstall"
  if [[ -n $SETUP_CODE ]] && qr_ok; then
    qr="${url}/#setup=${SETUP_CODE}"
    echo; echo "  Or scan this with your phone; it opens the page with the code filled in:"
    qrencode -t ansiutf8 "$qr" | sed 's/^/    /' || true
  fi
  final_box "$url"
  wait_for_account
}

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
  ASSUME_YES=0; ALLOW_DOWNGRADE=0; USE_EXISTING_DOCKER=0; CLOUD=0; TAKE_OVER_PORTS=0; SSH_KEYS_ONLY=0; KEEP_SSH_PASSWORDS=0; SSH_STATE=""
  SKIP_HARDENING="${SKIP_HARDENING:-0}"; SKIP_SYSTEM_UPDATE="${SKIP_SYSTEM_UPDATE:-0}"
  LOCAL_MODE="${TEND_LOCAL_MODE:-}"; LOCAL_NAME="${TEND_LOCAL_NAME:-tend}"; LOCAL_NAME_GIVEN=0
  [[ -z ${TEND_LOCAL_NAME:-} ]] || LOCAL_NAME_GIVEN=1
  DOMAIN="${TEND_HOST_DOMAIN:-}"; DOMAIN_EMAIL="${TEND_HOST_DOMAIN_EMAIL:-}"
  case "${LOCAL_MODE,,}" in 1 | true | yes) LOCAL_MODE=1 ;; 0 | false | no) LOCAL_MODE=0 ;; "") ;; *) die "TEND_LOCAL_MODE must be 1 or 0." ;; esac
  local arg
  for arg in "$@"; do
    case "$arg" in
      --local) LOCAL_MODE=1 ;; --public) LOCAL_MODE=0 ;; --local-name=*) LOCAL_NAME="${arg#*=}"; LOCAL_NAME_GIVEN=1 ;;
      --allow-downgrade) ALLOW_DOWNGRADE=1 ;; --use-existing-docker) USE_EXISTING_DOCKER=1 ;; -y | --yes) ASSUME_YES=1 ;; --take-over-ports) TAKE_OVER_PORTS=1 ;;
      --ssh-keys-only) SSH_KEYS_ONLY=1 ;; --keep-ssh-passwords) KEEP_SSH_PASSWORDS=1 ;;
      -h | --help) usage; exit 0 ;;
      *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
    esac
  done
  [[ $SSH_KEYS_ONLY == 0 || $KEEP_SSH_PASSWORDS == 0 ]] || { echo "Choose one: --ssh-keys-only or --keep-ssh-passwords (see --help)" >&2; exit 2; }
  [[ -n ${TEND_M_IMAGE_DIGEST:-} && -n ${TEND_M_VERSION:-} && -n ${TEND_M_IMAGE:-} ]] ||
    die "Run this through install.sh, which verifies the signed release first: curl -fsSL https://get.tend.host/install.sh | sudo bash"
  trap cleanup_on_exit EXIT
  IMAGE_REF="${TEND_M_IMAGE}:${TEND_M_VERSION}@${TEND_M_IMAGE_DIGEST}"
  [[ -z ${TEND_SETUP_CODE:-} ]] || valid_setup_code "$TEND_SETUP_CODE" || die "TEND_SETUP_CODE must have at least 12 characters (spaces and hyphens do not count)."
  preflight
  # Before anything is read: the version decision below must see the state a
  # panel self-update left, and nothing may finish between that read and the
  # rewrite of the stack. (Released by cleanup_on_exit.)
  take_update_lock

  local state="$INSTALL_DIR/.tend-install.json" installed="" old_profile=""
  if [[ -f $state ]]; then
    installed="$(state_get "$state" version || true)"; old_profile="$(state_get "$state" profile || true)"
    if [[ -n $installed ]]; then
      if [[ $(version_cmp "$TEND_M_VERSION" "$installed") == -1 && $ALLOW_DOWNGRADE != 1 ]]; then
        die "Version $installed is installed and the release channel offers $TEND_M_VERSION, which is older. Re-run with --allow-downgrade if you mean it."
      fi
      if [[ $(version_cmp "$installed" "$TEND_M_MIN_UPGRADE_FROM") == -1 ]]; then
        die "This release upgrades from $TEND_M_MIN_UPGRADE_FROM or newer; version $installed is installed. Upgrade to $TEND_M_MIN_UPGRADE_FROM first."
      fi
    fi
    [[ -n $LOCAL_MODE || -z $old_profile ]] || { [[ $old_profile == home ]] && LOCAL_MODE=1 || LOCAL_MODE=0; }
    if [[ $LOCAL_NAME_GIVEN != 1 && -n $(state_get "$state" local_name || true) ]]; then
      LOCAL_NAME="$(state_get "$state" local_name)"; LOCAL_NAME="${LOCAL_NAME%.local}"
    fi
  fi

  choose_profile
  if [[ $PROFILE == home ]]; then
    LAN_IPS="$(ip -o -4 addr show scope global 2> /dev/null | interface_addrs lan | sort -u | tr '\n' ' ')"; LAN_IPS="${LAN_IPS% }"
    LAN_IP="$(ip -o -4 route get 1.1.1.1 2> /dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}')"
    is_lan_ipv4 "${LAN_IP:-}" || LAN_IP="${LAN_IPS%% *}"
    [[ -n $LAN_IP ]] || die "No home-network address was found on this machine. Is it connected to your router?"
    PUBLIC_IP=""; PANEL_FQDN=""
  else
    LAN_IP=""; LAN_IPS=""; PUBLIC_IP="$(detect_public_ip)"
    [[ -n $PUBLIC_IP ]] || die "Could not find this server's public address. Set it yourself: TEND_PUBLIC_IP=<address> and run this again."
    is_ipv4 "$PUBLIC_IP" || die "Tend needs a public IPv4 address for now; found $PUBLIC_IP."
    PANEL_FQDN="${DOMAIN:-$(saved_panel_fqdn "$state" "$PUBLIC_IP")}"
    [[ -n $PANEL_FQDN ]] || PANEL_FQDN="$(sslip_name "$PUBLIC_IP")"
    if [[ -n $DOMAIN ]]; then
      [[ $(getent ahostsv4 "$DOMAIN" 2> /dev/null | awk 'NR==1 {print $1}') == "$PUBLIC_IP" ]] ||
        c_warn "$DOMAIN does not point to $PUBLIC_IP yet. The certificate will wait for that DNS record."
    fi
  fi

  # Same version, same digest, same profile and running: nothing to do.
  if [[ -n $installed && $installed == "$TEND_M_VERSION" && -n $old_profile && $old_profile == "$PROFILE" ]] &&
    [[ "$(state_get "$state" image_digest || true)" == "$TEND_M_IMAGE_DIGEST" ]] && panel_healthy > /dev/null 2>&1; then
    c_ok "Tend $installed is up to date and running."; read_setup_code; final_box; exit 0
  fi

  if [[ $PROFILE == vps ]]; then update_system; fi
  install_base_packages
  if [[ $PROFILE == vps ]]; then harden_vps; else harden_home; fi
  ssh_keys_only_step
  install_docker
  if [[ $PROFILE == home ]]; then install_lan_firewall; else drop_home_leftovers; fi
  write_stack
  take_over_ports
  start_stack
  c_step "Waiting for Tend to start (up to 2 minutes)"
  if ! wait_for 120 panel_healthy; then echo; rollback; die "Tend did not answer within 2 minutes. Look at: cd $INSTALL_DIR && docker compose logs --tail=80"; fi
  echo; c_ok "The panel is running"
  verify_addresses
  render_state "$TEND_M_VERSION" "$TEND_M_IMAGE_DIGEST" "${TEND_CHANNEL:-stable}" "$PROFILE" "${PANEL_FQDN}" "$([[ $PROFILE == home ]] && echo "${LOCAL_NAME}.local")" "$PUBLIC_IP" "$LAN_IP" "$TEND_M_IMAGE" > "$state"
  render_helper > "$HELPER"; chmod 0755 "$HELPER"
  read_setup_code
  install_claim_banner
  summary
}

# Run only when executed; the tests source this file for the functions above.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi

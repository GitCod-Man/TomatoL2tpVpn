#!/bin/sh
#
# Script for automatic setup of an IPsec VPN server on Ubuntu, Debian, CentOS/RHEL,
# Rocky Linux, AlmaLinux, Oracle Linux, Amazon Linux 2 and Alpine Linux
#
# DO NOT RUN THIS SCRIPT ON YOUR PC OR MAC!


YOUR_IPSEC_PSK='GGGGZZZZZZZZ'
YOUR_USERNAME=''
YOUR_PASSWORD=''



export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

exiterr() { echo "Error: $1" >&2; exit 1; }

check_ip() {
  IP_REGEX='^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$'
  printf '%s' "$1" | tr -d '\n' | grep -Eq "$IP_REGEX"
}

check_dns_name() {
  FQDN_REGEX='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
  printf '%s' "$1" | tr -d '\n' | grep -Eq "$FQDN_REGEX"
}




check_os() {
  rh_file="/etc/redhat-release"
  if [ -f "$rh_file" ]; then
    os_type=centos
    if grep -q "Red Hat" "$rh_file"; then
      os_type=rhel
    fi
    [ -f /etc/oracle-release ] && os_type=ol
    grep -qi rocky "$rh_file" && os_type=rocky
    grep -qi alma "$rh_file" && os_type=alma
    if grep -q "release 7" "$rh_file"; then
      os_ver=7
    elif grep -q "release 8" "$rh_file"; then
      os_ver=8
      grep -qi stream "$rh_file" && os_ver=8s
      if [ "$os_type$os_ver" = "centos8" ]; then
        exiterr "CentOS Linux 8 is EOL and not supported."
      fi
    elif grep -q "release 9" "$rh_file"; then
      os_ver=9
      grep -qi stream "$rh_file" && os_ver=9s
    else
      exiterr "This script only supports CentOS/RHEL 7-9."
    fi
  elif grep -qs "Amazon Linux release 2" /etc/system-release; then
    os_type=amzn
    os_ver=2
  else
    os_type=$(lsb_release -si 2>/dev/null)
    [ -z "$os_type" ] && [ -f /etc/os-release ] && os_type=$(. /etc/os-release && printf '%s' "$ID")
    case $os_type in
      [Uu]buntu)
        os_type=ubuntu
        ;;
      [Dd]ebian|[Kk]ali)
        os_type=debian
        ;;
      [Rr]aspbian)
        os_type=raspbian
        ;;
      [Aa]lpine)
        os_type=alpine
        ;;
      *)
cat 1>&2 <<'EOF'
Error: This script only supports one of the following OS:
       Ubuntu, Debian, CentOS/RHEL, Rocky Linux, AlmaLinux,
       Oracle Linux, Amazon Linux 2 or Alpine Linux
EOF
        exit 1
        ;;
    esac
    if [ "$os_type" = "alpine" ]; then
      os_ver=$(. /etc/os-release && printf '%s' "$VERSION_ID" | cut -d '.' -f 1,2)
      if [ "$os_ver" != "3.15" ] && [ "$os_ver" != "3.16" ]; then
        exiterr "This script only supports Alpine Linux 3.15/3.16."
      fi
    else
      os_ver=$(sed 's/\..*//' /etc/debian_version | tr -dc 'A-Za-z0-9')
      if [ "$os_ver" = 8 ] || [ "$os_ver" = "jessiesid" ]; then
        exiterr "Debian 8 or Ubuntu < 16.04 is not supported."
      fi
    fi
  fi
}

check_iface() {
  def_iface=$(route 2>/dev/null | grep -m 1 '^default' | grep -o '[^ ]*$')
  if [ "$os_type" != "alpine" ]; then
    [ -z "$def_iface" ] && def_iface=$(ip -4 route list 0/0 2>/dev/null | grep -m 1 -Po '(?<=dev )(\S+)')
  fi
  def_state=$(cat "/sys/class/net/$def_iface/operstate" 2>/dev/null)
  check_wl=0
  if [ -n "$def_state" ] && [ "$def_state" != "down" ]; then
    if [ "$os_type" = "ubuntu" ] || [ "$os_type" = "debian" ] || [ "$os_type" = "raspbian" ]; then
      if ! uname -m | grep -qi -e '^arm' -e '^aarch64'; then
        check_wl=1
      fi
    else
      check_wl=1
    fi
  fi
  if [ "$check_wl" = 1 ]; then
    case $def_iface in
      wl*)
        exiterr "Wireless interface '$def_iface' detected. DO NOT run this script on your PC or Mac!"
        ;;
    esac
  fi
}

check_creds() {
  [ -n "$YOUR_IPSEC_PSK" ] && VPN_IPSEC_PSK="$YOUR_IPSEC_PSK"
  [ -n "$YOUR_USERNAME" ] && VPN_USER="$YOUR_USERNAME"
  [ -n "$YOUR_PASSWORD" ] && VPN_PASSWORD="$YOUR_PASSWORD"
  if [ -z "$VPN_IPSEC_PSK" ] && [ -z "$VPN_USER" ] && [ -z "$VPN_PASSWORD" ]; then
    return 0
  fi
  if [ -z "$VPN_IPSEC_PSK" ] || [ -z "$VPN_USER" ] || [ -z "$VPN_PASSWORD" ]; then
    exiterr "All VPN credentials must be specified. Edit the script and re-enter them."
  fi
  if printf '%s' "$VPN_IPSEC_PSK $VPN_USER $VPN_PASSWORD" | LC_ALL=C grep -q '[^ -~]\+'; then
    exiterr "VPN credentials must not contain non-ASCII characters."
  fi
  case "$VPN_IPSEC_PSK $VPN_USER $VPN_PASSWORD" in
    *[\\\"\']*)
      exiterr "VPN credentials must not contain these special characters: \\ \" '"
      ;;
  esac
}

check_dns() {
  if { [ -n "$VPN_DNS_SRV1" ] && ! check_ip "$VPN_DNS_SRV1"; } \
    || { [ -n "$VPN_DNS_SRV2" ] && ! check_ip "$VPN_DNS_SRV2"; }; then
    exiterr "The DNS server specified is invalid."
  fi
}

check_server_dns() {
  if [ -n "$VPN_DNS_NAME" ] && ! check_dns_name "$VPN_DNS_NAME"; then
    exiterr "Invalid DNS name. 'VPN_DNS_NAME' must be a fully qualified domain name (FQDN)."
  fi
}

check_client_name() {
  if [ -n "$VPN_CLIENT_NAME" ]; then
    name_len="$(printf '%s' "$VPN_CLIENT_NAME" | wc -m)"
    if [ "$name_len" -gt "64" ] || printf '%s' "$VPN_CLIENT_NAME" | LC_ALL=C grep -q '[^A-Za-z0-9_-]\+' \
      || case $VPN_CLIENT_NAME in -*) true ;; *) false ;; esac; then
      exiterr "Invalid client name. Use one word only, no special characters except '-' and '_'."
    fi
  fi
}

wait_for_apt() {
  count=0
  apt_lk=/var/lib/apt/lists/lock
  pkg_lk=/var/lib/dpkg/lock
  while fuser "$apt_lk" "$pkg_lk" >/dev/null 2>&1 \
    || lsof "$apt_lk" >/dev/null 2>&1 || lsof "$pkg_lk" >/dev/null 2>&1; do
    [ "$count" = 0 ] && echo "## Waiting for apt to be available..."
    [ "$count" -ge 100 ] && exiterr "Could not get apt/dpkg lock."
    count=$((count+1))
    printf '%s' '.'
    sleep 3
  done
}

install_pkgs() {
  if ! command -v wget >/dev/null 2>&1; then
    if [ "$os_type" = "ubuntu" ] || [ "$os_type" = "debian" ] || [ "$os_type" = "raspbian" ]; then
      wait_for_apt
      export DEBIAN_FRONTEND=noninteractive
      (
        set -x
        apt-get -yqq update || apt-get -yqq update
      ) || exiterr "'apt-get update' failed."
      (
        set -x
        apt-get -yqq install wget >/dev/null || apt-get -yqq install wget >/dev/null
      ) || exiterr "'apt-get install wget' failed."
    elif [ "$os_type" != "alpine" ]; then
      (
        set -x
        yum -y -q install wget >/dev/null || yum -y -q install wget >/dev/null
      ) || exiterr "'yum install wget' failed."
    fi
  fi
  if [ "$os_type" = "alpine" ]; then
    (
      set -x
      apk add -U -q bash coreutils grep net-tools sed wget
    ) || exiterr "'apk add' failed."
  fi
}



vpnsetup() {
  check_root
  check_vz
  check_lxc
  check_os
  check_iface
  check_creds
  check_dns
  check_server_dns
  check_client_name
  install_pkgs
  get_setup_url
  run_setup
}

## Defer setup until we have the complete script
vpnsetup "$@"

exit "$status"

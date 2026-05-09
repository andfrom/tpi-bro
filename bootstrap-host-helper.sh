#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-}"

case "$cmd" in
  hosts-append)
    shift
    if [ "$(id -u)" -ne 0 ]; then
      echo "This needs sudo. Re-run: sudo $0 hosts-append $*"
      exit 1
    fi
    args=("$@")
    i=0
    while [ $i -lt ${#args[@]} ]; do
      ip="${args[$i]}"; name="${args[$((i+1))]}"
      i=$((i+2))
      [ -z "$ip" ] || [ -z "$name" ] && continue
      if ! grep -qE "^[[:space:]]*$ip[[:space:]].*\b$name\b" /etc/hosts; then
        echo "$ip $name" >> /etc/hosts
        echo "added: $ip $name"
      else
        echo "exists: $ip $name"
      fi
    done
    ;;
  hosts-remove)
    shift
    if [ "$(id -u)" -ne 0 ]; then
      echo "This needs sudo. Re-run: sudo $0 hosts-remove $*"
      exit 1
    fi
    for name in "$@"; do
      [ -z "$name" ] && continue
      if grep -qE "\b${name}\b" /etc/hosts; then
        sed -i "/\b${name}\b/d" /etc/hosts
        echo "removed: $name"
      else
        echo "not found: $name"
      fi
    done
    ;;
  *)
    echo "Usage:"
    echo "  $0 hosts-append <ip1> <name1> [<ip2> <name2> ...]"
    echo "  $0 hosts-remove <name1> [<name2> ...]"
    exit 1
    ;;
esac

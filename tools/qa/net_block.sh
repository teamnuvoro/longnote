#!/usr/bin/env bash
# Makes the Longnote backend unreachable from this Mac (and so from the iOS
# Simulator, which uses the Mac's network): /etc/hosts sends the Supabase
# hosts to 127.0.0.1 (connection refused at once) and a pf anchor rejects
# their current IPs (in case an address is cached). `off` undoes both.
# Needs sudo (GitHub macOS runners have it without a password).
# Usage: tools/qa/net_block.sh on|off [out_dir]
set -uo pipefail
MODE=${1:?on|off}
OUT=${2:-}
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
URL=$(sed -n "s/.*_defaultUrl = 'https:\/\/\([^']*\)'.*/\1/p" "$ROOT/lib/core/cloud/backend_config.dart")
REF=${URL%%.*}
HOSTS="$URL $REF.storage.supabase.co"
ANCHOR="com.apple/250.LongnoteQA"
MARK="# longnote-qa"

probe() { curl -sS -m 8 -o /dev/null -w '%{http_code}' "https://$URL/auth/v1/health" 2>&1 | tail -c 120; }
flush() { sudo dscacheutil -flushcache 2>/dev/null; sudo killall -HUP mDNSResponder 2>/dev/null; true; }

if [ "$MODE" = on ]; then
  IPS=$(python3 - "$HOSTS" <<'PY'
import socket, sys
ips = set()
for h in sys.argv[1].split():
    try:
        for fam, *_rest, addr in socket.getaddrinfo(h, 443, proto=socket.IPPROTO_TCP):
            ips.add(addr[0])
    except OSError:
        pass
print(" ".join(sorted(ips)))
PY
)
  RULES=""
  for ip in $IPS; do
    if [[ $ip == *:* ]]; then RULES+="block return out quick inet6 proto tcp from any to $ip"$'\n'
    else RULES+="block return out quick inet proto tcp from any to $ip"$'\n'; fi
  done
  sudo pfctl -f /etc/pf.conf >/dev/null 2>&1 || true
  [ -n "$RULES" ] && printf '%s' "$RULES" | sudo pfctl -a "$ANCHOR" -f - 2>&1 | grep -v ALTQ || true
  sudo pfctl -E >/dev/null 2>&1 || true
  for h in $HOSTS; do
    printf '127.0.0.1 %s %s\n::1 %s %s\n' "$h" "$MARK" "$h" "$MARK" | sudo tee -a /etc/hosts >/dev/null
  done
  flush; sleep 2
  MSG="blocked $HOSTS (pf: ${IPS:-none}); probe from the Mac: $(probe)"
else
  sudo pfctl -a "$ANCHOR" -F all >/dev/null 2>&1 || true
  sudo sed -i '' "/$MARK/d" /etc/hosts
  flush; sleep 2
  MSG="unblocked $HOSTS; probe from the Mac: $(probe)"
fi
echo "$MSG"
if [ -n "$OUT" ]; then
  mkdir -p "$OUT/requests"
  [ "$MODE" = on ] && echo "$MSG" > "$OUT/requests/blocked-state"
  echo "$(date -u +%FT%TZ) $MSG" >> "$OUT/logs/network.log"
fi

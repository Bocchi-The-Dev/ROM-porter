#!/usr/bin/env bash
# upload_gofile.sh <file> [file...]
# Uploads files to GoFile (guest upload, no account needed) and prints the
# download page links. Uses only curl + python3.
set -euo pipefail

if [ $# -eq 0 ]; then
  echo "Usage: $0 <file> [file...]"
  exit 1
fi

for F in "$@"; do
  [ -f "$F" ] || { echo "ERROR: not found: $F"; exit 1; }
done

get_server() {
  curl -fsSL --retry 3 --max-time 60 "https://api.gofile.io/servers" | python3 -c "
import json, sys
d = json.load(sys.stdin)
servers = d.get('data', {}).get('servers', [])
if not servers:
    sys.exit('no servers in GoFile response')
print(servers[0]['name'])
"
}

SERVER="$(get_server)"
echo "GoFile server: $SERVER" >&2

FAILED=0
for F in "$@"; do
  echo "Uploading $(basename "$F") ($(du -h "$F" | cut -f1)) ..." >&2
  LINK="$(curl -fsSL --retry 3 --max-time 1200 -F "file=@$F" "https://$SERVER.gofile.io/uploadFile" | python3 -c "
import json, sys
d = json.load(sys.stdin)
if d.get('status') != 'ok':
    sys.exit('upload failed: %s' % d)
print(d['data']['downloadPage'])
")" || FAILED=1
  if [ "$FAILED" -ne 0 ]; then
    echo "ERROR: upload failed for $F" >&2
    exit 1
  fi
  echo "$F -> $LINK"
done

echo ""
echo "NOTE: guest uploads expire after ~10 days of inactivity."

#!/bin/sh
# Runs on the reMarkable 2. Fetches the dashboard PNG and draws it with FBInk via rm2fb.
# Requires rm2fb.service running and xochitl stopped (see README).
# Only redraws when the image changed; does a full (flashing) refresh once an hour to clear ghosting.
URL="${WALL_URL:-http://10.0.0.97:8765/dashboard.png}"
DIR=/home/root/wall-display
mkdir -p "$DIR"

wget -q -T 20 -O "$DIR/new.png" "$URL" || exit 0
NEW=$(md5sum "$DIR/new.png" | cut -d' ' -f1)
OLD=$(cat "$DIR/last.md5" 2>/dev/null)
[ "$NEW" = "$OLD" ] && exit 0

HOUR=$(date +%H)
if [ "$HOUR" != "$(cat "$DIR/last.hour" 2>/dev/null)" ]; then
  FLAGS="-f"   # full flashing refresh
  echo "$HOUR" > "$DIR/last.hour"
fi

LD_PRELOAD=/opt/lib/librm2fb_client.so /opt/bin/fbink -q -c $FLAGS -g file="$DIR/new.png" && echo "$NEW" > "$DIR/last.md5"

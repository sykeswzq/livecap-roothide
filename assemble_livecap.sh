#!/bin/sh
cd /tmp
rm -f LiveCap_v1.0.77.deb livecap_part_*
for i in $(seq 0 99); do
    f="/tmp/livecap_part_$i.txt"
    if [ -f "$f" ]; then
        cat "$f" >> livecap_part_$i.b64
        rm "$f"
    fi
done
# Now concatenate all parts and decode
cat /tmp/livecap_part_*.b64 | base64 -d > /tmp/LiveCap_v1.0.77.deb
ls -la /tmp/LiveCap_v1.0.77.deb

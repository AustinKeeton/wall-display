#!/bin/sh
# Sleep/wake test: deep sleep 60s on RTC alarm, then measure Wi-Fi reconnect and redraw.
LOG=/home/root/sleeptest.log
BAT=/sys/class/power_supply/max77818_battery
URL=http://10.0.0.97:8765/dashboard.png
log() { echo "$(date +%H:%M:%S) $*" >> $LOG; }
: > $LOG
log "start battery=$(cat $BAT/capacity)% current_ma=$(( $(cat $BAT/current_now) / 1000 ))"
sync
echo 0 > /sys/class/rtc/rtc0/wakealarm
echo +60 > /sys/class/rtc/rtc0/wakealarm
T0=$(date +%s)
log "suspending via systemctl (runs wifi sleep hook), alarm in 60s"
systemctl suspend; RC=$?
sleep 5  # monotonic: only counts awake time, so this returns ~5s after resume
T1=$(date +%s)
log "resumed rc=$RC elapsed_s=$((T1 - T0)) (includes ~5s awake) wake_source=$(cat /sys/power/pm_wakeup_irq 2>/dev/null)"
i=0
until ping -c 1 -W 1 10.0.0.105 >/dev/null 2>&1; do i=$((i+1)); [ $i -ge 60 ] && break; sleep 1; done
T2=$(date +%s)
log "wifi_up_after_s=$((T2 - T1)) ip=$(ip -4 addr show wlan0 | grep -o 'inet [0-9.]*')"
if wget -q -T 15 -O /tmp/wake.png "$URL"; then
  LD_PRELOAD=/opt/lib/librm2fb_client.so /opt/bin/fbink -q -c -f -g file=/tmp/wake.png >/dev/null 2>&1
  log "redraw fbink_rc=$? total_awake_s=$(( $(date +%s) - T1 ))"
else
  log "download FAILED"
fi
log "end battery=$(cat $BAT/capacity)%"
log "DONE"

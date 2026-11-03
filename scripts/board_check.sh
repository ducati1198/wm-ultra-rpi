#!/bin/bash
# Read-only look at the new setup: Is the main board there? Is the CAN bus up? Are the services as expected?
# Changes nothing, starts nothing. Run it on the Raspberry Pi.
ok(){ echo "  [ok]   $1"; }; no(){ echo "  [--]   $1"; }; info(){ echo "         $1"; }
echo "Main board (Klipper USB-CAN bridge)"
if lsusb 2>/dev/null | grep -qi '1d50:606f'; then ok "USB device 1d50:606f found"; else no "no 1d50:606f on USB (main board not connected or not powered)"; fi
echo "CAN bus"
if ip -details link show can0 >/dev/null 2>&1; then
  ip -details link show can0 | sed -n '1p;3,4p' | sed 's/^/         /'
  ip link show can0 | grep -q 'state UP\|UP,LOWER_UP' && ok "can0 is up" || no "can0 exists but is down"
else no "no can0 interface yet"; fi
echo "Toolheads / hub on the bus (Klipper must be stopped to query)"
if systemctl is-active --quiet klipper; then info "Klipper is running: skipped (it owns the bus)"
elif [ -x "$HOME/klippy-env/bin/python" ] && [ -f "$HOME/klipper/scripts/canbus_query.py" ] && ip link show can0 >/dev/null 2>&1; then
  "$HOME/klippy-env/bin/python" "$HOME/klipper/scripts/canbus_query.py" can0 2>&1 | sed 's/^/         /'
else info "skipped (no can0 or no canbus_query.py)"; fi
echo "Serial devices"; ls /dev/serial/by-id 2>/dev/null | sed 's/^/         /' || true
echo "Services"
for s in moonraker nginx klipper; do printf '  %-10s active=%s enabled=%s\n' "$s" "$(systemctl is-active $s 2>/dev/null)" "$(systemctl is-enabled $s 2>/dev/null)"; done
echo "Web"; curl -fsS -m 5 http://127.0.0.1:7125/server/info 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin)["result"];print("         Moonraker",d.get("moonraker_version"),"klippy_state:",d.get("klippy_state"))' 2>/dev/null || no "Moonraker did not answer"

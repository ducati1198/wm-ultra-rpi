#!/bin/bash
# READ-ONLY. Run on the WonderMaker screen board (WM-ZR-M, RK3308B) to see how its display, touch and apps work.
# It changes nothing: no installs, no service changes, no writes except the report file.
#   scp scripts/screen_board_inspect.sh t13dp@<board-ip>:/tmp/ && ssh t13dp@<board-ip> 'bash /tmp/screen_board_inspect.sh'
# Then send me /tmp/screen_board_report.txt (secrets and private addresses are removed).
OUT=/tmp/screen_board_report.txt
sec() { printf '\n===== %s =====\n' "$1"; }
{
echo "screen_board_inspect $(date -u +%FT%TZ) user=$(id -un)"
sec "OS / kernel / CPU / RAM / disk"; cat /etc/os-release 2>/dev/null; uname -a; tr '\0' ' ' </proc/device-tree/model 2>/dev/null; echo; nproc; free -m; df -h / /home 2>/dev/null
sec "Python / GTK / apt availability"; python3 --version 2>&1; python3 -c 'import gi;print("gi",gi.__version__)' 2>&1; for p in libgtk-3-0 xserver-xorg xinit weston cage libinput-tools; do printf '%s: ' "$p"; dpkg -s "$p" 2>/dev/null | grep -m1 '^Version' || echo not-installed; done
sec "Enabled services"; systemctl list-unit-files --state=enabled --no-pager 2>&1
sec "Running services"; systemctl list-units --type=service --state=running --no-pager 2>&1
sec "Custom service files (not from the OS)"; ls -la /etc/systemd/system/*.service 2>/dev/null; ls /home/*/ 2>/dev/null
sec "Autostart / rc.local / cron"; cat /etc/rc.local 2>/dev/null; ls /etc/xdg/autostart ~/.config/autostart 2>/dev/null; crontab -l 2>&1; ls /etc/cron.d 2>/dev/null
sec "Processes (top by memory)"; ps -eo pid,user,rss,args --sort=-rss | head -30
sec "Display: DRM / framebuffer / X / Wayland"; ls -la /dev/dri /dev/fb* 2>&1; for f in /sys/class/drm/*/status; do [ -r "$f" ] && echo "$f: $(cat $f) $(head -n1 $(dirname $f)/modes 2>/dev/null)"; done; ps -ef | grep -E 'Xorg|Xwayland|weston|cage|lvgl|qt|gtk' | grep -v grep; cat /sys/class/graphics/fb0/virtual_size 2>/dev/null
sec "Backlight"; ls /sys/class/backlight 2>&1
sec "Touch / input devices"; cat /proc/bus/input/devices 2>&1; for e in /sys/class/input/event*; do echo "$e: $(udevadm info -q property -p $e 2>/dev/null | grep -E 'ID_INPUT_TOUCHSCREEN|NAME=' | tr '\n' ' ')"; done
sec "Kernel modules / dmesg (display, touch, drm)"; lsmod 2>&1 | head -40; dmesg 2>/dev/null | grep -i -E 'drm|panel|touch|goodix|ft5|dsi|lcd|rockchip.*vop|input' | tail -30
sec "Network"; ip -br addr; ip route; nmcli -t -f NAME,TYPE con 2>&1 | head
sec "Home folders and the app"; ls -la ~ ; ls -la ~/printer_data 2>&1 | head -20; find / -xdev \( -iname '*screen*' -o -iname '*wonder*' -o -iname '*lvgl*' -o -iname '*gui*' \) -maxdepth 4 -not -path '/proc/*' -not -path '/usr/share/*' -not -path '/usr/lib/*' 2>/dev/null | head -40
sec "Boot config"; cat /boot/extlinux/extlinux.conf /boot/uEnv.txt /boot/armbianEnv.txt 2>/dev/null | head -40
sec "Klipper/Moonraker versions"; ls ~/klipper ~/moonraker 2>&1 | head -5; git -C ~/klipper log -1 --format=%H 2>&1
} 2>&1 | sed -E 's/((password|passwd|token|api_?key|secret|ssid|psk|key)[[:space:]]*[:=][[:space:]]*).*/\1<removed>/I; s/\b(10\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+)\b/<private-ip>/g; s/([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}/<mac>/g' > "$OUT"
echo "Done. Report: $OUT ($(wc -l < "$OUT") lines). Nothing was changed."

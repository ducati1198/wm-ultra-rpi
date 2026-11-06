#!/bin/bash
# Copies the WonderMaker software from the old screen/host board to a stage folder.
# Read-only on the old board: it only runs `tar` there. Nothing is written or changed on it.
#
#   ./pull_from_board.sh <board-ip> [stage-dir] [ssh-user]
#
# Result: <stage-dir>/{klipper,moonraker,data}.tgz   (default stage-dir: ./stage)
# The files are WonderMaker's and yours (printer.cfg, calibration). They never go into this repo.
set -eu
BOARD="${1:-}"; STAGE="${2:-./stage}"; RUSER="${3:-t13dp}"
[ -n "$BOARD" ] || { echo "Usage: $0 <board-ip> [stage-dir] [ssh-user]"; exit 1; }
mkdir -p "$STAGE"
# One SSH connection for all steps: the first command asks for the password, the others reuse that connection
# (ControlMaster), so the password is typed once, not once per step. The connection is closed when this script ends.
CTL_DIR="$(mktemp -d /tmp/wmpull.XXXXXX)"
trap 'ssh -O exit -o ControlPath="$CTL_DIR/c" "$RUSER@$BOARD" 2>/dev/null; rm -rf "$CTL_DIR"' EXIT
SSH=(ssh -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15 -o ControlMaster=auto -o "ControlPath=$CTL_DIR/c" -o ControlPersist=600 "$RUSER@$BOARD")
if [ -n "${WM_SSH_PASSWORD:-}" ] && command -v sshpass >/dev/null; then SSH=(sshpass -e "${SSH[@]}"); export SSHPASS="$WM_SSH_PASSWORD"; fi

echo "Checking the board ($RUSER@$BOARD)..."
"${SSH[@]}" 'test -d /home/t13dp/klipper && test -d /home/t13dp/moonraker && test -d /home/t13dp/printer_data' \
  || { echo "That does not look like a WonderMaker board (no ~/klipper, ~/moonraker, ~/printer_data)."; exit 1; }

pull() {  # name, remote tar arguments
  local name="$1"; shift
  echo "  $name ..."
  "${SSH[@]}" "cd /home/t13dp && tar czf - $*" > "$STAGE/$name.tgz.part"
  mv "$STAGE/$name.tgz.part" "$STAGE/$name.tgz"
}
pull klipper    "--exclude=__pycache__ klipper"
pull moonraker  "--exclude=__pycache__ moonraker"
pull data       "--exclude=printer_data/gcodes --exclude=printer_data/logs --exclude=printer_data/comms \
                 printer_data fluidd \$(ls -d TM_T1/factory_settings TM_T1/scripts 2>/dev/null)"
echo "Done: $(du -sh "$STAGE" | cut -f1) in $STAGE"

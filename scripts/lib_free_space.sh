#!/usr/bin/env bash
# Shared "Free up disk space" code. Loaded (sourced) by installer.sh and scripts/screen_board.sh.
# The caller sets before calling: FREE_NEED_MB, FS_LOGS_DIR (printer logs folder), HOME_DIR, REPO_DIR,
# TESTING, DRY and defines: SUDO, ask_yn, print_header/success/info/warning, disk_free_mb, DIM, NC, YELLOW.
declare -a FS_ID FS_LABEL FS_KB FS_WARN FS_SUDO
fs_add() { FS_ID+=("$1"); FS_LABEL+=("$2"); FS_KB+=("$3"); FS_WARN+=("$4"); FS_SUDO+=("$5"); }
fs_kb() { local k; [ $# -gt 0 ] || { echo 0; return; }; k="$(du -sk "$@" 2>/dev/null | awk '{s+=$1} END{print s+0}')"; echo "${k:-0}"; }
fs_tmpdirs() {   # leftover downloads of this installer in /tmp: only folders made by this user that hold a copy of wm-ultra-rpi
    local base="${WM_TEST_TMP:-/tmp}" d
    for d in "$base"/tmp.*; do [ -d "$d" ] && [ -f "$d/VERSION" ] && [ -f "$d/scripts/screen_board.sh" ] && [ "$(stat -c %U "$d" 2>/dev/null)" = "$(id -un)" ] && echo "$d"; done
}
fs_scan() {
    FS_ID=(); FS_LABEL=(); FS_KB=(); FS_WARN=(); FS_SUDO=()
    local kb d list=()
    while read -r d; do [ -n "$d" ] && list+=("$d"); done < <(fs_tmpdirs)
    if [ ${#list[@]} -gt 0 ]; then kb="$(fs_kb "${list[@]}")"; fs_add tmp "Leftover installer downloads in /tmp (${#list[@]} folder(s))" "$kb" "Copies of this installer that an older 'Update now' left behind. Nothing else is in them." 0; fi
    kb="$(fs_kb "$HOME_DIR/.cache/pip")"; fs_add pip "pip download cache (~/.cache/pip)" "$kb" "Downloaded Python packages. They are downloaded again only if you reinstall something." 0
    if [ "$TESTING" = 1 ]; then kb="${WM_TEST_APT_KB:-0}"; else kb="$(fs_kb /var/cache/apt/archives)"; fi
    fs_add apt "apt package cache (/var/cache/apt/archives)" "$kb" "Downloaded .deb files of packages that are already installed. Installed programs are not touched." 1
    if [ "$TESTING" = 1 ]; then kb="${WM_TEST_JOURNAL_KB:-0}"; else kb="$(fs_kb /var/log/journal)"; kb=$(( kb > 51200 ? kb - 51200 : 0 )); fi
    fs_add journal "Old system log history (keeps the newest 50 MB)" "$kb" "Erases older system messages (journalctl). Only useful when looking for an old problem." 1
    kb="$(fs_kb $(ls "$FS_LOGS_DIR"/*.log.* 2>/dev/null))"; fs_add oldlogs "Old rotated printer logs (~/printer_data/logs/*.log.*)" "$kb" "Older copies of klippy/moonraker logs. The current logs stay." 0
    # (tests only ever touch a copy of the installer folder, never the real repository)
    if [ -d "$REPO_DIR/.git" ] && case "$(basename "$REPO_DIR")" in wm-ultra-rpi*) true ;; *) false ;; esac && { [ "$TESTING" != 1 ] || [ "${WM_TEST_REFRESH_REPO:-0}" = 1 ]; }; then kb="$(fs_kb "$REPO_DIR/.git")"; fs_add gitdir "Git history of the downloaded installer ($REPO_DIR/.git)" "$kb" "After this, 'git pull' no longer works in that folder; 'Update now' in the menu downloads the newest files instead." 0; fi
}
fs_free_text() { echo "  Free space now: $(disk_free_mb) MB   (the install needs about $FREE_NEED_MB MB)"; }
fs_do() {   # id
    case "$1" in
        tmp) local d; while read -r d; do [ -n "$d" ] && rm -rf "$d"; done < <(fs_tmpdirs) ;;
        pip) rm -rf "$HOME_DIR/.cache/pip" ;;
        apt) SUDO apt-get clean ;;
        journal) SUDO journalctl --vacuum-size=50M ;;
        oldlogs) rm -f "$FS_LOGS_DIR"/*.log.* ;;
        gitdir) rm -rf "$REPO_DIR/.git" ;;
    esac
}
do_free_space() {   # lists what can be erased safely, with sizes and a warning for each; erases only what you pick and confirm
    print_header "Free up disk space"
    fs_free_text
    fs_scan
    local i n=0 idx=() ans pick=() total=0 k
    for i in "${!FS_ID[@]}"; do
        [ "${FS_KB[$i]}" -ge 1024 ] || continue
        n=$((n+1)); idx+=("$i")
        printf '   %s) %-62s %5s MB%s\n' "$n" "${FS_LABEL[$i]}" "$(( FS_KB[i] / 1024 ))" "$([ "${FS_SUDO[$i]}" = 1 ] && echo '  (asks for sudo)')"
        echo -e "      ${DIM}${FS_WARN[$i]}${NC}"
    done
    [ "$n" -gt 0 ] || { print_info "Nothing safe to erase was found. Free space yourself: old files in ~/printer_data/gcodes, or other large files (du -xh ~ --max-depth=1 | sort -rh | head)."; return 0; }
    echo "  Your gcode files, your settings, KlipperScreen and the factory software are never in this list."
    if [ "${WM_ASSUME_YES:-0}" = 1 ]; then ans="all"; else read -r -p "  Type the numbers to erase (for example 1 3), 'all', or press Enter to cancel: " ans || ans=""; fi
    ans="$(echo "$ans" | tr ',' ' ')"
    [ -n "$ans" ] || { echo "  Nothing was erased."; return 0; }
    if [ "$ans" = all ]; then pick=("${idx[@]}"); else
        for k in $ans; do [[ "$k" =~ ^[0-9]+$ ]] && [ "$k" -ge 1 ] && [ "$k" -le "$n" ] && pick+=("${idx[$((k-1))]}") || { print_warning "'$k' is not in the list."; return 0; }; done
    fi
    echo; echo -e "  ${YELLOW}This will ERASE:${NC}"
    for i in "${pick[@]}"; do echo "    - ${FS_LABEL[$i]}  (about $(( FS_KB[i] / 1024 )) MB)"; echo -e "      ${DIM}${FS_WARN[$i]}${NC}"; total=$((total + FS_KB[i])); done
    if [ "$DRY" = 1 ]; then echo -e "  ${DIM}(dry run: nothing is erased)${NC}"; return 0; fi
    ask_yn "Erase these now? About $((total/1024)) MB will be freed" n || { echo "  Nothing was erased."; return 0; }
    local fi_=0; for i in "${pick[@]}"; do progress_bar "$fi_" "${#pick[@]}" "Erasing (step $((fi_+1)) of ${#pick[@]})"; fs_do "${FS_ID[$i]}"; fi_=$((fi_+1)); done
    progress_bar "${#pick[@]}" "${#pick[@]}" "Done"
    [ "$TESTING" = 1 ] && export WM_TEST_DISK_MB=$(( ${WM_TEST_DISK_MB:-4000} + total/1024 ))
    print_success "Erased. Free space now: $(disk_free_mb) MB"
}


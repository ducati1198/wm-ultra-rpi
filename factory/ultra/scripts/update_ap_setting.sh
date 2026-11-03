#!/bin/bash
# AP Configuration Script Based on Serial Number
# Usage: setup-ap-by-sn.sh [options] <serial-number>
# Options:
#   -s, --ssid SSID       Set custom SSID (overrides generated one)
#   -p, --password PASS   Set custom password (overrides generated one)
#   -h, --help            Show this help

# Configuration directories
CONFIG_DIR="/etc/makerbase-ap"
AP_CTRL_PATH="/usr/local/bin/makerbase-ap-ctrl"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_status() {
    echo -e "${GREEN}[+]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[-]${NC} $1"
}

show_help() {
    cat << EOF
Usage: $0 [options] <serial-number>

Options:
  -s, --ssid SSID         Set custom SSID (overrides generated one)
  -p, --password PASS     Set custom password (overrides generated one)
  -h, --help              Show this help message

Serial number formats supported:
  1. 16-digit hexadecimal (e.g., a1b2c3d4e5f67890)
  2. Model + 6-12 digit decimal (e.g., ZRUS20251230017)

Examples:
  $0 a1b2c3d4e5f67890
  $0 ZRUS20251230017
  $0 --ssid "MyCustomAP" --password "MySecret123" ZRUS20251230017
  $0 -s "TestAP" -p "87654321" a1b2c3d4e5f67890
EOF
    exit 0
}

# Parse command line options
parse_arguments() {
    # Initialize variables
    SN=""
    CUSTOM_SSID=""
    CUSTOM_PASSWORD=""
    
    # Use manual parsing to support both short and long options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--ssid)
                if [[ -z "$2" || "$2" == -* ]]; then
                    print_error "Option $1 requires an argument"
                    exit 1
                fi
                CUSTOM_SSID="$2"
                shift 2
                ;;
            -p|--password)
                if [[ -z "$2" || "$2" == -* ]]; then
                    print_error "Option $1 requires an argument"
                    exit 1
                fi
                CUSTOM_PASSWORD="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                ;;
            -*)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                # First non-option argument is the serial number
                if [[ -z "$SN" ]]; then
                    SN="$1"
                else
                    print_error "Unexpected extra argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Check that serial number is provided
    if [[ -z "$SN" ]]; then
        print_error "Serial number is required"
        show_help
        exit 1
    fi

    # Validate custom password length if provided (WPA2 requires at least 8)
    if [[ -n "$CUSTOM_PASSWORD" && ${#CUSTOM_PASSWORD} -lt 8 ]]; then
        print_warning "Custom password length (${#CUSTOM_PASSWORD}) is less than 8 characters, which may not be accepted by WPA2"
    fi

    # Validate serial number format
    SN_UPPER=$(echo "$SN" | tr '[:lower:]' '[:upper:]')
    detect_sn_type
}

# Detect SN type and validate format
detect_sn_type() {
    SN_TYPE=""
    MODEL=""
    NUMERIC_PART=""

    # Check for old format: 16-digit hexadecimal
    if echo "$SN" | grep -qE '^[0-9a-fA-F]{16}$'; then
        SN_TYPE="OLD"
        print_status "Detected old format SN (16-digit hexadecimal)"
        return 0
    fi

    # Check for new format: Model (ZR|ZRU|ZRUS) + 6-12 digit decimal
    if echo "$SN_UPPER" | grep -qE '^(ZR|ZRU|ZRUS)[0-9]{6,12}$'; then
        SN_TYPE="NEW"
        if [[ "$SN_UPPER" =~ ^(ZR|ZRU|ZRUS)([0-9]{6,12})$ ]]; then
            MODEL="${BASH_REMATCH[1]}"
            NUMERIC_PART="${BASH_REMATCH[2]}"
        else
            # Fallback
            if [[ "$SN_UPPER" == ZRUS* ]]; then
                MODEL="ZRUS"
                NUMERIC_PART="${SN_UPPER:4}"
            elif [[ "$SN_UPPER" == ZRU* ]]; then
                MODEL="ZRU"
                NUMERIC_PART="${SN_UPPER:3}"
            elif [[ "$SN_UPPER" == ZR* ]]; then
                MODEL="ZR"
                NUMERIC_PART="${SN_UPPER:2}"
            fi
        fi
        print_status "Detected new format SN (Model: $MODEL, Numeric: $NUMERIC_PART)"
        return 0
    fi

    print_error "Invalid serial number format"
    echo "Supported formats:"
    echo "  1. 16-digit hexadecimal (e.g., a1b2c3d4e5f67890)"
    echo "  2. Model + 6-12 digit decimal (e.g., ZRUS20251230017)"
    echo ""
    echo "Received: $SN"
    exit 1
}

# Calculate X value (0-255)
calculate_x() {
    local input_str="$1"
    local sum=0
    for (( i=0; i<${#input_str}; i++ )); do
        char="${input_str:$i:1}"
        ascii_val=$(printf "%d" "'$char")
        sum=$((sum + ascii_val))
    done
    echo $((sum % 256))
}

# Generate password if not custom
calculate_password() {
    local input_str="$1"
    if command -v md5sum >/dev/null 2>&1; then
        md5_hash=$(echo -n "$input_str" | md5sum | cut -d' ' -f1)
    elif command -v md5 >/dev/null 2>&1; then
        md5_hash=$(echo -n "$input_str" | md5 | cut -d' ' -f1)
    else
        print_error "MD5 calculation tool not found (md5sum or md5)"
        exit 1
    fi
    password_raw="${md5_hash:0:8}"
    password=$(echo "$password_raw" | tr '[:upper:]' '[:lower:]')
    if ! echo "$password" | grep -qE '^[0-9a-z]{8}$'; then
        print_warning "Generated password format invalid, using fallback method"
        password=$(echo "$md5_hash" | tail -c 9 | head -c 8 | tr '[:upper:]' '[:lower:]')
        if ! echo "$password" | grep -qE '^[0-9a-z]{8}$'; then
            password="12345678"
        fi
    fi
    echo "$password"
}

# Determine final SSID (custom or generated)
determine_ssid() {
    if [[ -n "$CUSTOM_SSID" ]]; then
        SSID="$CUSTOM_SSID"
        SSID_SOURCE="Custom"
        # Optional warning for length > 32
        if [ ${#SSID} -gt 32 ]; then
            print_warning "Custom SSID length (${#SSID}) > 32 may exceed Wi-Fi standard limit"
        fi
    else
        if [ "$SN_TYPE" = "OLD" ]; then
            SSID_SUFFIX="${SN_UPPER:0:6}"
            SSID="WM_ZRU_${SSID_SUFFIX}"
        else
            SSID="WM_${MODEL}_${NUMERIC_PART}"
        fi
        SSID_SOURCE="Generated"
    fi
    print_status "SSID: $SSID ($SSID_SOURCE)"
}

# Backup configuration files
backup_config() {
    local file="$1"
    if [ -f "$file" ]; then
        backup="${file}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$file" "$backup"
        print_status "Backed up $file to $backup"
    fi
}

# Update hostapd.conf
update_hostapd() {
    print_header "Updating hostapd.conf"
    cat > "$CONFIG_DIR/hostapd.conf" <<EOF
# Auto-generated on $(date)
# Serial Number: $SN
# Type: $SN_TYPE
# SSID Source: $SSID_SOURCE
# Password Source: $PASSWORD_SOURCE
interface=wlan0
driver=nl80211
ssid=$SSID
wpa_passphrase=$PASSWORD
hw_mode=g
channel=6
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
country_code=CN
EOF
    print_status "hostapd.conf updated successfully"
    echo "  • SSID: $SSID ($SSID_SOURCE)"
    echo "  • Password: $PASSWORD ($PASSWORD_SOURCE)"
}

# Update dnsmasq.conf
update_dnsmasq() {
    print_header "Updating dnsmasq.conf"
    cat > "$CONFIG_DIR/dnsmasq.conf" <<EOF
# Auto-generated on $(date)
# Serial Number: $SN
# Type: $SN_TYPE
# Network: 192.168.$X.0/24
interface=wlan0
no-resolv
no-hosts
domain=wondermaker.local
dhcp-range=192.168.$X.100,192.168.$X.200,255.255.255.0,2h
dhcp-option=3,192.168.$X.1
dhcp-option=6,192.168.$X.1
dhcp-leasefile=/var/lib/misc/dnsmasq.wondermaker.leases
log-queries
log-dhcp
EOF
    print_status "dnsmasq.conf updated successfully"
    echo "  • Network: 192.168.$X.0/24"
    echo "  • DHCP Range: 192.168.$X.100 - 192.168.$X.200"
    echo "  • Gateway/DNS: 192.168.$X.1"
}

# Update makerbase-ap-ctrl script IP configuration
update_ap_ctrl() {
    print_header "Updating makerbase-ap-ctrl script"
    if [ ! -f "$AP_CTRL_PATH" ]; then
        print_error "makerbase-ap-ctrl script not found at $AP_CTRL_PATH"
        return 1
    fi
    tmp_file=$(mktemp)
    while IFS= read -r line; do
        if echo "$line" | grep -q "ip addr add 192\.168\.[0-9]\{1,3\}\.1/24 dev wlan0"; then
            echo "  ip addr add 192.168.$X.1/24 dev wlan0"
        elif echo "$line" | grep -q "192\.168\.[0-9]\{1,3\}\.1"; then
            new_line=$(echo "$line" | sed "s/192\.168\.[0-9]\{1,3\}\.1/192.168.$X.1/g")
            echo "$new_line"
        else
            echo "$line"
        fi
    done < "$AP_CTRL_PATH" > "$tmp_file"
    cp "$tmp_file" "$AP_CTRL_PATH"
    chmod +x "$AP_CTRL_PATH"
    rm -f "$tmp_file"
    print_status "makerbase-ap-ctrl script updated successfully"
    echo "  • AP IP Address: 192.168.$X.1/24"
}

# Create configuration record file
create_config_record() {
    record_file="$CONFIG_DIR/last_config.txt"
    {
        echo "# AP Configuration Record"
        echo "Generated: $(date)"
        echo "Serial Number: $SN"
        if [ "$SN_TYPE" = "OLD" ]; then
            echo "Type: Old Format (16-digit hexadecimal)"
        else
            echo "Type: New Format (Model: $MODEL, Numeric: $NUMERIC_PART)"
        fi
        echo "SSID: $SSID"
        echo "Source of SSID: $SSID_SOURCE"
        echo "Password: $PASSWORD"
        echo "Source of Password: $PASSWORD_SOURCE"
        echo "Calculated Parameters:"
        echo "  X Value: $X"
        echo "  Network: 192.168.$X.0/24"
        echo "Configuration Files:"
        echo "  hostapd.conf: $CONFIG_DIR/hostapd.conf"
        echo "  dnsmasq.conf: $CONFIG_DIR/dnsmasq.conf"
        echo "  makerbase-ap-ctrl: $AP_CTRL_PATH"
    } > "$record_file"
    print_status "Configuration saved to: $record_file"
}

# Validate dependencies
validate_dependencies() {
    print_header "Checking Dependencies"
    missing_tools=()
    if ! command -v md5sum >/dev/null 2>&1 && ! command -v md5 >/dev/null 2>&1; then
        missing_tools+=("md5sum or md5")
    fi
    for tool in iw ip hostapd dnsmasq; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    if [ ${#missing_tools[@]} -gt 0 ]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        echo "Please install missing tools before proceeding."
        return 1
    fi
    print_status "All dependencies are satisfied"
    return 0
}

# Display configuration summary
display_summary() {
    print_header "Configuration Summary"
    echo "Serial Number: $SN"
    echo "Type: $SN_TYPE"
    if [ "$SN_TYPE" = "NEW" ]; then
        echo "Model: $MODEL"
        echo "Numeric Part: $NUMERIC_PART"
    fi
    echo "SSID: $SSID ($SSID_SOURCE)"
    echo "Password: $PASSWORD ($PASSWORD_SOURCE)"
    echo "X Value: $X"
    echo "Network: 192.168.$X.0/24"
    echo ""
    echo "Configuration Files Updated:"
    echo "  ✓ $CONFIG_DIR/hostapd.conf"
    echo "  ✓ $CONFIG_DIR/dnsmasq.conf"
    echo "  ✓ $AP_CTRL_PATH"
}

# Display usage instructions
display_instructions() {
    print_header "Usage Instructions"
    echo "To start the AP with new configuration:"
    echo "  sudo systemctl start makerbase-ap"
    echo ""
    echo "To stop the AP:"
    echo "  sudo systemctl stop makerbase-ap"
    echo ""
    echo "To check AP status:"
    echo "  sudo makerbase-ap-ctrl status"
    echo "  or"
    echo "  sudo systemctl status makerbase-ap"
    echo ""
    echo "To view connected clients:"
    echo "  sudo iw dev wlan0 station dump"
    echo ""
    print_warning "If AP service is currently running, restart it to apply changes:"
    echo "  sudo systemctl restart makerbase-ap"
}

# Main execution flow
main() {
    mkdir -p "$CONFIG_DIR"
    if ! validate_dependencies; then
        exit 1
    fi

    # Calculate X value (always based on SN)
    X=$(calculate_x "$SN")

    # Determine password
    if [[ -n "$CUSTOM_PASSWORD" ]]; then
        PASSWORD="$CUSTOM_PASSWORD"
        PASSWORD_SOURCE="Custom"
    else
        PASSWORD=$(calculate_password "$SN")
        PASSWORD_SOURCE="Generated"
    fi

    # Determine SSID
    determine_ssid   # sets SSID and SSID_SOURCE

    # Update configurations
    update_hostapd
    update_dnsmasq
    update_ap_ctrl
    create_config_record

    # Display results
    display_summary
    print_header "Configuration Complete"
    print_status "AP is ready to be started with the new configuration"
}

# ---- Script entry point ----
parse_arguments "$@"
main

exit 0
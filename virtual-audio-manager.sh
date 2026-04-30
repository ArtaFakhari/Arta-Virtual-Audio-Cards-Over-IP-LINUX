#!/usr/bin/env bash
# =============================================================================
# Name:        virtual-audio-manager.sh
# Author:      Arta
# Version:     1.0.0
# Description: Manage virtual PipeWire audio sinks with network streaming,
#              volume control, and XDG-compliant persistence. Designed for
#              modern Linux desktops using native PipeWire/WirePlumber APIs.
#              Supports graphical DE integration (GNOME, KDE, LXDE, Wayfire)
#              and network audio over TCP (protocol-simple) or RTP.
# License:     MIT
# Repository:  https://github.com/ArtaFakhari/Arta-Virtual-Audio-Cards-Over-IP-LINUX
#
# MIT License
# Copyright (c) 2026 Arta
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# ANSI Color Codes
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ---------------------------------------------------------------------------
# Configuration paths (XDG-compliant)
# ---------------------------------------------------------------------------
CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/pipewire/pipewire.conf.d"
CONFIG_FILE="${CONFIG_DIR}/virtual-audio-cards.conf"

# ---------------------------------------------------------------------------
# In-memory state: associative arrays keyed by PipeWire Node ID
#   STREAM_PROTO[id]   -> "tcp" or "rtp"
#   STREAM_ADDR[id]    -> target IP
#   STREAM_PORT[id]    -> port number
#   STREAM_PID[id]     -> background pw-cli loader PID (TCP only)
# ---------------------------------------------------------------------------
declare -A STREAM_PROTO=()
declare -A STREAM_ADDR=()
declare -A STREAM_PORT=()
declare -A STREAM_PID=()

# ---------------------------------------------------------------------------
# Helper: print a styled message
# ---------------------------------------------------------------------------
info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# 1. ROOT GUARD — never run as root; PipeWire is per-user
# ---------------------------------------------------------------------------
if [[ "${EUID}" -eq 0 ]]; then
    die "Do not run this script as root. PipeWire runs in user session context."
fi

# ---------------------------------------------------------------------------
# 2. DEPENDENCY CHECKS
# ---------------------------------------------------------------------------
check_dependencies() {
    local -a required_bins=(pipewire wireplumber pw-cli pw-dump wpctl jq bc ss)
    local missing=()

    for bin in "${required_bins[@]}"; do
        if ! command -v "${bin}" &>/dev/null; then
            missing+=("${bin}")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required binaries: ${missing[*]}"
        echo -e "  Install them with your package manager, e.g.:"
        echo -e "  ${CYAN}sudo apt install pipewire wireplumber pipewire-bin jq bc iproute2${RESET}"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# 3. SERVICE CHECKS — PipeWire and WirePlumber must be running
# ---------------------------------------------------------------------------
check_services() {
    local -a services=(pipewire wireplumber)
    for svc in "${services[@]}"; do
        if ! systemctl --user is-active --quiet "${svc}"; then
            error "User service '${svc}' is not active."
            echo -e "  Start it with: ${CYAN}systemctl --user start ${svc}${RESET}"
            exit 1
        fi
    done
}

# ---------------------------------------------------------------------------
# 4. INPUT VALIDATION HELPERS
# ---------------------------------------------------------------------------

# Validate sink name: alphanumeric, underscore, hyphen only
validate_sink_name() {
    local name="$1"
    if [[ ! "${name}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        return 1
    fi
    return 0
}

# Validate port: integer in [1024, 65535]
validate_port() {
    local port="$1"
    if [[ ! "${port}" =~ ^[0-9]+$ ]] || \
       (( port < 1024 || port > 65535 )); then
        return 1
    fi
    return 0
}

# Validate IPv4 address (basic regex; covers 0.0.0.0-255.255.255.255)
validate_ip() {
    local ip="$1"
    local octet='(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)'
    if [[ ! "${ip}" =~ ^${octet}\.${octet}\.${octet}\.${octet}$ ]]; then
        return 1
    fi
    return 0
}

# Check whether a TCP port is already bound
port_in_use() {
    local port="$1"
    ss -tlnH "sport = :${port}" 2>/dev/null | grep -q .
}

# Confirm a PipeWire Node ID still exists
node_exists() {
    local node_id="$1"
    pw-cli info "${node_id}" &>/dev/null
}

# ---------------------------------------------------------------------------
# 5. QUERY VIRTUAL SINKS
#    Returns JSON array of objects with id/name/description/volume/mute
#    We only list nodes whose media.class == "Audio/Sink" and whose
#    node.name starts with "virtual_" (our naming convention).
# ---------------------------------------------------------------------------
get_virtual_sinks_json() {
    # pw-dump emits a JSON array of all PipeWire objects.
    # We filter for Node type + Audio/Sink class + our name prefix.
    pw-dump 2>/dev/null | jq -c '
        [
          .[] |
          select(
            .type == "PipeWire:Interface:Node" and
            .info.props["media.class"] == "Audio/Sink" and
            (.info.props["node.name"] // "" | test("^virtual_"))
          ) |
          {
            id:          .id,
            name:        (.info.props["node.name"]        // "unknown"),
            description: (.info.props["node.description"] // "unknown"),
            volume:      (
                           .info.params.Props[0].volume //
                           .info.params.Props[0].channelVolumes[0] //
                           null
                         ),
            mute:        (.info.params.Props[0].mute // false)
          }
        ]
    ' 2>/dev/null || echo "[]"
}

# Pretty-print the dashboard table
print_sink_table() {
    local sinks_json
    sinks_json="$(get_virtual_sinks_json)"
    local count
    count="$(echo "${sinks_json}" | jq 'length')"

    echo -e "${BOLD}${BLUE}Active Virtual Sinks${RESET}"
    echo -e "──────────────────────────────────────────────────────────────────"
    printf "  ${BOLD}%-6s %-28s %-20s %-8s %-6s %-22s${RESET}\n" \
           "ID" "Name" "Description" "Volume" "Mute" "Network Stream"
    echo -e "──────────────────────────────────────────────────────────────────"

    if [[ "${count}" -eq 0 ]]; then
        echo -e "  ${YELLOW}(no virtual sinks found)${RESET}"
    else
        while IFS= read -r sink; do
            local id name desc vol mute stream_info
            id="$(echo "${sink}"    | jq -r '.id')"
            name="$(echo "${sink}"  | jq -r '.name')"
            desc="$(echo "${sink}"  | jq -r '.description')"
            vol="$(echo "${sink}"   | jq -r '.volume // "N/A"')"
            mute="$(echo "${sink}"  | jq -r '.mute')"

            # Format volume as percentage
            if [[ "${vol}" != "N/A" ]]; then
                vol="$(echo "scale=0; ${vol} * 100 / 1" | bc)%"
            fi

            # Mute indicator
            if [[ "${mute}" == "true" ]]; then
                mute="${RED}MUTE${RESET}"
            else
                mute="${GREEN}live${RESET}"
            fi

            # Network stream info
            if [[ -n "${STREAM_PORT[${id}]+x}" ]]; then
                local proto="${STREAM_PROTO[${id}]}"
                local addr="${STREAM_ADDR[${id}]}"
                local port="${STREAM_PORT[${id}]}"
                stream_info="${CYAN}${proto}://${addr}:${port}${RESET}"
            else
                stream_info="-"
            fi

            printf "  %-6s %-28s %-20s %-8s %-14b %-22b\n" \
                   "${id}" "${name}" "${desc}" "${vol}" "${mute}" "${stream_info}"
        done < <(echo "${sinks_json}" | jq -c '.[]')
    fi
    echo -e "──────────────────────────────────────────────────────────────────"
}

# ---------------------------------------------------------------------------
# 6. CREATE VIRTUAL SINK
#    Uses pw-cli create-node adapter with properties required for DE
#    visibility in pavucontrol, GNOME/KDE tray applets, etc.
# ---------------------------------------------------------------------------
create_virtual_sink() {
    echo -e "\n${BOLD}Create Virtual Audio Sink${RESET}"

    # --- Sink Name ---
    local sink_name
    while true; do
        read -rp "  Sink name (alphanumeric, _ or -, no spaces): " sink_name
        if validate_sink_name "${sink_name}"; then
            break
        fi
        warn "Invalid name. Use only letters, digits, underscores, or hyphens."
    done

    # Prefix to distinguish our virtual sinks from system nodes
    local node_name="virtual_${sink_name}"

    # --- Description (shown in GUI applets) ---
    local description
    read -rp "  Description (shown in volume applets): " description
    # Strip control characters from free-form input
    description="${description//[$'\001'-$'\037']/}"
    description="${description//\"/\'}"   # replace double-quotes to avoid conf injection

    # --- Channel map ---
    echo "  Channel map options:"
    echo "    1) Stereo (FL,FR)  [default]"
    echo "    2) Mono   (MONO)"
    echo "    3) 5.1    (FL,FR,FC,LFE,SL,SR)"
    local ch_choice
    read -rp "  Choice [1]: " ch_choice
    local audio_position
    case "${ch_choice}" in
        2) audio_position="MONO"           ;;
        3) audio_position="FL,FR,FC,LFE,SL,SR" ;;
        *) audio_position="FL,FR"          ;;
    esac

    # --- Create the node via pw-cli ---
    # Properties breakdown:
    #   factory.name=support.null-audio-sink  — built-in null sink factory
    #   media.class=Audio/Sink                — REQUIRED for DE/tray visibility
    #   node.name                             — unique identifier in PipeWire graph
    #   node.description                      — human label in pavucontrol / tray
    #   audio.position                        — channel map for correct routing
    #   monitor.channel-volumes=true          — expose per-channel volume to wpctl
    #
    # pw-cli create-node <factory> <properties-spa-dict>
    local node_id
    node_id="$(
        pw-cli create-node adapter \
            "{ \
                factory.name=support.null-audio-sink \
                node.name=\"${node_name}\" \
                node.description=\"${description}\" \
                media.class=Audio/Sink \
                audio.position=${audio_position} \
                monitor.channel-volumes=true \
                object.linger=true \
            }" 2>&1 | grep -oP 'id \K[0-9]+' | head -1
    )" || true

    if [[ -z "${node_id}" ]]; then
        error "Failed to create virtual sink. Check that PipeWire is running."
        return 1
    fi

    success "Virtual sink '${node_name}' created with Node ID ${node_id}."
    echo -e "  Description : ${description}"
    echo -e "  Channel map : ${audio_position}"
    echo -e "  ${YELLOW}Tip:${RESET} It should now appear in pavucontrol and desktop volume applets."
}

# ---------------------------------------------------------------------------
# 7. DELETE VIRTUAL SINK
# ---------------------------------------------------------------------------
delete_virtual_sink() {
    echo -e "\n${BOLD}Delete Virtual Audio Sink${RESET}"
    print_sink_table

    local node_id
    read -rp "  Enter Node ID to delete (or blank to cancel): " node_id
    [[ -z "${node_id}" ]] && return 0

    if ! node_exists "${node_id}"; then
        error "Node ID ${node_id} does not exist."
        return 1
    fi

    # Safety: confirm
    local confirm
    read -rp "  Destroy node ${node_id}? [y/N]: " confirm
    [[ "${confirm,,}" != "y" ]] && { info "Cancelled."; return 0; }

    # Stop any associated stream
    if [[ -n "${STREAM_PID[${node_id}]+x}" ]]; then
        kill "${STREAM_PID[${node_id}]}" 2>/dev/null || true
        unset "STREAM_PID[${node_id}]" "STREAM_PROTO[${node_id}]" \
              "STREAM_ADDR[${node_id}]" "STREAM_PORT[${node_id}]"
    fi

    pw-cli destroy "${node_id}" || {
        error "Failed to destroy node ${node_id}."
        return 1
    }
    success "Node ${node_id} destroyed."
}

# ---------------------------------------------------------------------------
# 8. VOLUME CONTROL
# ---------------------------------------------------------------------------
volume_control() {
    echo -e "\n${BOLD}Volume Control${RESET}"
    print_sink_table

    local target
    read -rp "  Node ID or '@DEFAULT_AUDIO_SINK@' [default]: " target
    [[ -z "${target}" ]] && target="@DEFAULT_AUDIO_SINK@"

    # If numeric ID given, verify node exists
    if [[ "${target}" =~ ^[0-9]+$ ]]; then
        if ! node_exists "${target}"; then
            error "Node ID ${target} does not exist."
            return 1
        fi
    fi

    echo "  Volume actions:"
    echo "    1) Increase by 5%"
    echo "    2) Decrease by 5%"
    echo "    3) Set absolute value"
    echo "    4) Toggle mute"
    local action
    read -rp "  Choice: " action

    case "${action}" in
        1)
            # +5%, hard cap at 1.0
            wpctl set-volume "${target}" 5%+
            # Clamp: re-read volume and cap if over 1.0
            local raw_vol
            raw_vol="$(wpctl get-volume "${target}" 2>/dev/null | awk '{print $2}')"
            if [[ -n "${raw_vol}" ]]; then
                local capped
                capped="$(echo "if (${raw_vol} > 1.0) 1.0 else ${raw_vol}" | bc -l)"
                if (( $(echo "${raw_vol} > 1.0" | bc -l) )); then
                    wpctl set-volume "${target}" 1.0
                    warn "Volume capped at 100%."
                fi
            fi
            success "Volume increased."
            ;;
        2)
            wpctl set-volume "${target}" 5%-
            success "Volume decreased."
            ;;
        3)
            local pct
            read -rp "  Target volume percentage (0-100): " pct
            if [[ ! "${pct}" =~ ^[0-9]+$ ]] || (( pct < 0 || pct > 100 )); then
                error "Invalid percentage. Must be 0-100."
                return 1
            fi
            local vol_float
            vol_float="$(echo "scale=4; ${pct}/100" | bc)"
            wpctl set-volume "${target}" "${vol_float}"
            success "Volume set to ${pct}%."
            ;;
        4)
            wpctl set-mute "${target}" toggle
            success "Mute toggled."
            ;;
        *)
            warn "Unknown action."
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 9. NETWORK STREAMING
#    Two modes:
#      TCP  — pw-cli load-module libpipewire-module-protocol-simple
#      RTP  — pw-cli load-module libpipewire-module-rtp-sink
# ---------------------------------------------------------------------------
expose_sink_network() {
    echo -e "\n${BOLD}Expose Virtual Sink to Network${RESET}"
    print_sink_table

    local node_id
    read -rp "  Node ID to stream: " node_id
    [[ -z "${node_id}" ]] && return 0

    if ! node_exists "${node_id}"; then
        error "Node ID ${node_id} does not exist."
        return 1
    fi

    # Already streaming?
    if [[ -n "${STREAM_PORT[${node_id}]+x}" ]]; then
        warn "Node ${node_id} is already streaming on port ${STREAM_PORT[${node_id}]}."
        local upd
        read -rp "  Stop current stream and reconfigure? [y/N]: " upd
        [[ "${upd,,}" != "y" ]] && return 0
        _stop_stream "${node_id}"
    fi

    # Protocol choice
    echo "  Streaming protocol:"
    echo "    1) TCP  (protocol-simple, compatible with ffplay/VLC raw PCM)"
    echo "    2) RTP  (multicast/unicast, compatible with VLC/GStreamer)"
    local proto_choice
    read -rp "  Choice [1]: " proto_choice
    local proto
    case "${proto_choice}" in
        2) proto="rtp" ;;
        *) proto="tcp" ;;
    esac

    # Target address
    local addr
    read -rp "  Target IP address [127.0.0.1]: " addr
    [[ -z "${addr}" ]] && addr="127.0.0.1"
    if ! validate_ip "${addr}"; then
        error "Invalid IP address: ${addr}"
        return 1
    fi

    # Port
    local port
    read -rp "  Port [8080]: " port
    [[ -z "${port}" ]] && port="8080"
    if ! validate_port "${port}"; then
        error "Invalid port. Must be an integer between 1024 and 65535."
        return 1
    fi

    # Port collision check
    if port_in_use "${port}"; then
        error "Port ${port} is already in use. Choose a different port."
        return 1
    fi

    # Get the node's name for linking
    local node_name
    node_name="$(pw-dump 2>/dev/null | jq -r \
        --argjson id "${node_id}" \
        '.[] | select(.id == $id) | .info.props["node.name"] // empty' \
        2>/dev/null | head -1)"

    if [[ "${proto}" == "tcp" ]]; then
        _start_tcp_stream "${node_id}" "${node_name}" "${addr}" "${port}"
    else
        _start_rtp_stream "${node_id}" "${node_name}" "${addr}" "${port}"
    fi
}

# Start a TCP stream using libpipewire-module-protocol-simple
# Clients can connect with: ffplay -f s16le -ar 48000 -ac 2 tcp://127.0.0.1:8080
_start_tcp_stream() {
    local node_id="$1" node_name="$2" addr="$3" port="$4"

    # Load the protocol-simple module into the running PipeWire instance.
    # module.args properties:
    #   server.address   — tcp:<ip>:<port>
    #   audio.format     — S16LE raw PCM (widely compatible)
    #   audio.rate       — sample rate
    #   audio.channels   — stereo
    #   capture.props    — link to our specific virtual sink node by name
    local module_args
    module_args="{ \
        server.address = [ \"tcp:${addr}:${port}\" ] \
        audio.format   = S16LE \
        audio.rate     = 48000 \
        audio.channels = 2 \
        capture.props  = { \
            node.name  = \"${node_name}\" \
            stream.capture.sink = true \
        } \
    }"

    # pw-cli load-module runs in the foreground and blocks; run via subshell
    pw-cli load-module libpipewire-module-protocol-simple \
        "${module_args}" &>/tmp/pw-stream-"${node_id}".log &
    local pid=$!

    # Brief settle wait; check the process is still alive
    sleep 0.5
    if ! kill -0 "${pid}" 2>/dev/null; then
        error "TCP stream failed to start. See /tmp/pw-stream-${node_id}.log"
        return 1
    fi

    STREAM_PROTO["${node_id}"]="tcp"
    STREAM_ADDR["${node_id}"]="${addr}"
    STREAM_PORT["${node_id}"]="${port}"
    STREAM_PID["${node_id}"]="${pid}"

    success "TCP stream started: tcp://${addr}:${port}  (PID ${pid})"
    echo -e "  Connect with: ${CYAN}ffplay -f s16le -ar 48000 -ac 2 tcp://${addr}:${port}${RESET}"
    echo -e "  Or VLC:       ${CYAN}vlc tcp://${addr}:${port}${RESET}"
}

# Start an RTP stream using libpipewire-module-rtp-sink
_start_rtp_stream() {
    local node_id="$1" node_name="$2" addr="$3" port="$4"

    # module-rtp-sink properties:
    #   destination.ip   — unicast/multicast target
    #   destination.port — RTP destination port
    #   node.name        — source node to capture from
    #   sess.media       — "audio"
    local module_args
    module_args="{ \
        destination.ip   = \"${addr}\" \
        destination.port = ${port} \
        node.name        = \"${node_name}\" \
        sess.media       = \"audio\" \
        audio.format     = S16BE \
        audio.rate       = 48000 \
        audio.channels   = 2 \
    }"

    pw-cli load-module libpipewire-module-rtp-sink \
        "${module_args}" &>/tmp/pw-stream-"${node_id}".log &
    local pid=$!

    sleep 0.5
    if ! kill -0 "${pid}" 2>/dev/null; then
        error "RTP stream failed to start. See /tmp/pw-stream-${node_id}.log"
        return 1
    fi

    STREAM_PROTO["${node_id}"]="rtp"
    STREAM_ADDR["${node_id}"]="${addr}"
    STREAM_PORT["${node_id}"]="${port}"
    STREAM_PID["${node_id}"]="${pid}"

    success "RTP stream started: rtp://${addr}:${port}  (PID ${pid})"
    echo -e "  Connect with VLC: ${CYAN}vlc rtp://@:${port}${RESET}"
}

# Stop an active stream by Node ID
_stop_stream() {
    local node_id="$1"
    if [[ -n "${STREAM_PID[${node_id}]+x}" ]]; then
        kill "${STREAM_PID[${node_id}]}" 2>/dev/null || true
        unset "STREAM_PID[${node_id}]" "STREAM_PROTO[${node_id}]" \
              "STREAM_ADDR[${node_id}]" "STREAM_PORT[${node_id}]"
        success "Stream for node ${node_id} stopped."
    else
        warn "No active stream found for node ${node_id}."
    fi
}

# ---------------------------------------------------------------------------
# 10. UPDATE PORT of an active stream
# ---------------------------------------------------------------------------
update_stream_port() {
    echo -e "\n${BOLD}Update Network Stream Port${RESET}"
    print_sink_table

    local node_id
    read -rp "  Node ID whose port to update: " node_id
    [[ -z "${node_id}" ]] && return 0

    if [[ -z "${STREAM_PORT[${node_id}]+x}" ]]; then
        error "Node ${node_id} is not currently streaming."
        return 1
    fi

    local new_port
    read -rp "  New port [current: ${STREAM_PORT[${node_id}]}]: " new_port
    [[ -z "${new_port}" ]] && return 0

    if ! validate_port "${new_port}"; then
        error "Invalid port. Must be an integer between 1024 and 65535."
        return 1
    fi

    if port_in_use "${new_port}"; then
        error "Port ${new_port} is already in use."
        return 1
    fi

    local proto="${STREAM_PROTO[${node_id}]}"
    local addr="${STREAM_ADDR[${node_id}]}"
    local node_name
    node_name="$(pw-dump 2>/dev/null | jq -r \
        --argjson id "${node_id}" \
        '.[] | select(.id == $id) | .info.props["node.name"] // empty' \
        2>/dev/null | head -1)"

    _stop_stream "${node_id}"

    if [[ "${proto}" == "tcp" ]]; then
        _start_tcp_stream "${node_id}" "${node_name}" "${addr}" "${new_port}"
    else
        _start_rtp_stream "${node_id}" "${node_name}" "${addr}" "${new_port}"
    fi
}

# ---------------------------------------------------------------------------
# 11. STOP NETWORK STREAM (menu wrapper)
# ---------------------------------------------------------------------------
stop_stream_menu() {
    echo -e "\n${BOLD}Stop Network Stream${RESET}"
    print_sink_table

    local node_id
    read -rp "  Node ID to stop streaming: " node_id
    [[ -z "${node_id}" ]] && return 0
    _stop_stream "${node_id}"
}

# ---------------------------------------------------------------------------
# 12. SAVE CONFIG (XDG-compliant PipeWire .conf snippet)
#    Writes a pipewire.conf.d fragment that recreates the virtual sinks on
#    boot. media.class=Audio/Sink ensures DE tray applet visibility.
#    Port comments allow third-party GUIs or Web UIs to parse/modify ports.
# ---------------------------------------------------------------------------
save_config() {
    echo -e "\n${BOLD}Save Configuration${RESET}"

    local sinks_json
    sinks_json="$(get_virtual_sinks_json)"
    local count
    count="$(echo "${sinks_json}" | jq 'length')"

    if [[ "${count}" -eq 0 ]]; then
        warn "No virtual sinks active. Nothing to save."
        return 0
    fi

    mkdir -p "${CONFIG_DIR}"
    local tmp_file
    tmp_file="$(mktemp "${CONFIG_DIR}/.virtual-audio-cards.conf.XXXXXX")"

    # Ensure temp file is cleaned up on any error
    trap 'rm -f "${tmp_file}"' ERR

    {
        cat <<'EOF'
# =============================================================================
# virtual-audio-cards.conf
# Generated by virtual-audio-manager.sh
# DO NOT EDIT the node blocks by hand unless you know PipeWire conf syntax.
#
# NETWORK PORTS: Lines tagged "# STREAM_PORT" below are parsed by GUIs.
# Format: # STREAM_PORT <node_name> <proto> <addr> <port>
# =============================================================================

context.modules = [
EOF

        while IFS= read -r sink; do
            local id name desc
            id="$(echo "${sink}"   | jq -r '.id')"
            name="$(echo "${sink}" | jq -r '.name')"
            desc="$(echo "${sink}" | jq -r '.description')"

            # Derive audio.position from live node props
            local pos
            pos="$(pw-dump 2>/dev/null | jq -r \
                --argjson nid "${id}" \
                '.[] | select(.id==$nid) | .info.props["audio.position"] // "FL,FR"' \
                2>/dev/null | head -1)"
            [[ -z "${pos}" ]] && pos="FL,FR"

            echo "  # Virtual Sink: ${name}"
            echo "  # Description : ${desc}"

            # Emit stream port comment if streaming
            if [[ -n "${STREAM_PORT[${id}]+x}" ]]; then
                echo "  # STREAM_PORT ${name} ${STREAM_PROTO[${id}]} ${STREAM_ADDR[${id}]} ${STREAM_PORT[${id}]}"
            fi

            cat <<NODEBLOCK
  {   name = libpipewire-module-adapter
      args = {
          factory.name     = support.null-audio-sink
          node.name        = "${name}"
          node.description = "${desc}"
          media.class      = Audio/Sink
          audio.position   = [ ${pos//,/ } ]
          monitor.channel-volumes = true
          object.linger    = true
      }
  }
NODEBLOCK
        done < <(echo "${sinks_json}" | jq -c '.[]')

        echo "]"
    } > "${tmp_file}"

    # Verify the temp file is non-empty before promoting
    if [[ ! -s "${tmp_file}" ]]; then
        rm -f "${tmp_file}"
        error "Config generation produced an empty file. Aborting save."
        return 1
    fi

    mv "${tmp_file}" "${CONFIG_FILE}"
    trap - ERR
    success "Configuration saved to ${CONFIG_FILE}"
    echo -e "  ${YELLOW}Reload with:${RESET} systemctl --user restart pipewire wireplumber"
}

# ---------------------------------------------------------------------------
# 13. DASHBOARD HEADER
# ---------------------------------------------------------------------------
print_header() {
    clear
    echo -e "${BOLD}${BLUE}"
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║       Virtual Audio Card Manager  —  PipeWire/WirePlumber   ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
    print_sink_table
    echo ""
}

# ---------------------------------------------------------------------------
# 14. MAIN MENU LOOP
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        print_header

        echo -e "${BOLD}Menu${RESET}"
        echo "  1) Create virtual sink"
        echo "  2) Delete virtual sink"
        echo "  3) Volume control"
        echo "  4) Expose sink to network (TCP/RTP)"
        echo "  5) Update stream port"
        echo "  6) Stop stream"
        echo "  7) Save config to ${CONFIG_FILE}"
        echo "  q) Quit"
        echo ""

        local choice
        read -rp "  Choice: " choice

        case "${choice}" in
            1) create_virtual_sink   ;;
            2) delete_virtual_sink   ;;
            3) volume_control        ;;
            4) expose_sink_network   ;;
            5) update_stream_port    ;;
            6) stop_stream_menu      ;;
            7) save_config           ;;
            q|Q) echo -e "\n${GREEN}Goodbye.${RESET}"; exit 0 ;;
            *) warn "Unknown option: ${choice}" ;;
        esac

        echo ""
        read -rp "  Press Enter to return to menu..." _pause
    done
}

# ---------------------------------------------------------------------------
# ENTRYPOINT
# ---------------------------------------------------------------------------
check_dependencies
check_services
main_menu

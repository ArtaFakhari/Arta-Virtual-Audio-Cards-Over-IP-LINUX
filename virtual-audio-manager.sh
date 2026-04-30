#!/usr/bin/env bash
# =============================================================================
# Name:        virtual-audio-manager.sh
# Author:      Arta
# Version:     1.1.0
# Description: Native PipeWire / WirePlumber virtual audio sink manager for
#              Linux desktops. Creates GUI-visible virtual sinks, controls
#              volume, exposes sinks over TCP/RTP, and writes XDG-compliant
#              persistence snippets for PipeWire.
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

SCRIPT_NAME="virtual-audio-manager.sh"
VERSION="1.1.0"
REPO_URL="https://github.com/ArtaFakhari/Arta-Virtual-Audio-Cards-Over-IP-LINUX"
RAW_SCRIPT_URL="https://raw.githubusercontent.com/ArtaFakhari/Arta-Virtual-Audio-Cards-Over-IP-LINUX/main/virtual-audio-manager.sh"

# ---------------------------------------------------------------------------
# ANSI color output (auto-disabled when stdout is not a terminal)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
    RESET=''
fi

# ---------------------------------------------------------------------------
# XDG-compliant paths
# ---------------------------------------------------------------------------
CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/pipewire/pipewire.conf.d"
CONFIG_FILE="${CONFIG_DIR}/virtual-audio-cards.conf"
STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/virtual-audio-manager"
RUNTIME_STATE_FILE="${STATE_DIR}/runtime-streams.tsv"
LOG_DIR="${STATE_DIR}/logs"

# ---------------------------------------------------------------------------
# Runtime stream state keyed by PipeWire sink node ID
#   STREAM_PROTO[id]      -> tcp | rtp
#   STREAM_ADDR[id]       -> target IP
#   STREAM_PORT[id]       -> target port
#   STREAM_MODULE_ID[id]  -> actual PipeWire module ID (not shell PID)
# ---------------------------------------------------------------------------
declare -A STREAM_PROTO=()
declare -A STREAM_ADDR=()
declare -A STREAM_PORT=()
declare -A STREAM_MODULE_ID=()

# ---------------------------------------------------------------------------
# Styled log helpers
# ---------------------------------------------------------------------------
info()    { printf '%b\n' "${BLUE}[INFO]${RESET}  $*"; }
success() { printf '%b\n' "${GREEN}[OK]${RESET}    $*"; }
warn()    { printf '%b\n' "${YELLOW}[WARN]${RESET}  $*"; }
error()   { printf '%b\n' "${RED}[ERROR]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Root guard: PipeWire and WirePlumber are user-session services
# ---------------------------------------------------------------------------
if [[ "${EUID}" -eq 0 ]]; then
    die "Do not run this script as root. PipeWire must be managed from the user session."
fi

# ---------------------------------------------------------------------------
# Terminal IO setup
#
# Why this exists:
#   A script launched as `curl ... | bash` or `bash <(curl ...)` does not read
#   its prompts from a normal stdin TTY. We reopen /dev/tty on custom file
#   descriptors so interactive reads still work in one-line remote launches.
# ---------------------------------------------------------------------------
setup_terminal_io() {
    if [[ -t 0 ]]; then
        exec 3<&0
    elif [[ -r /dev/tty ]]; then
        exec 3</dev/tty
    else
        die "Interactive terminal input is required. Try running this from a real terminal session."
    fi

    if [[ -t 1 ]]; then
        exec 4>&1
    elif [[ -w /dev/tty ]]; then
        exec 4>/dev/tty
    else
        exec 4>&2
    fi
}

tty_printf() {
    printf '%b' "$*" >&4
}

prompt_input() {
    local __var_name="$1"
    local prompt_text="$2"
    local default_value="${3-}"
    local reply=""

    if [[ -n "${default_value}" ]]; then
        tty_printf "${prompt_text} [${default_value}]: "
    else
        tty_printf "${prompt_text}"
    fi

    if ! IFS= read -r -u 3 reply; then
        tty_printf "\n"
        die "Failed to read input from the terminal."
    fi

    if [[ -z "${reply}" && -n "${default_value}" ]]; then
        reply="${default_value}"
    fi

    printf -v "${__var_name}" '%s' "${reply}"
}

confirm_action() {
    local reply=""
    prompt_input reply "$1 [y/N]: "
    [[ "${reply,,}" =~ ^y(es)?$ ]]
}

pause_for_user() {
    tty_printf "  Press Enter to return to menu..."
    IFS= read -r -u 3 _pause || true
}

show_usage() {
    cat <<EOF
${SCRIPT_NAME} ${VERSION}

Interactive PipeWire / WirePlumber virtual audio sink manager.

Usage:
  ./${SCRIPT_NAME}
  bash ${SCRIPT_NAME}
  bash <(curl -fsSL ${RAW_SCRIPT_URL})
  curl -fsSL ${RAW_SCRIPT_URL} | bash

Options:
  -h, --help       Show this help message
  -V, --version    Print the script version

Repository:
  ${REPO_URL}
EOF
}

# ---------------------------------------------------------------------------
# Utility helpers
# ---------------------------------------------------------------------------
ensure_runtime_dirs() {
    mkdir -p "${CONFIG_DIR}" "${STATE_DIR}" "${LOG_DIR}"
}

sanitize_description() {
    local description="$1"
    description="${description//[$'\001'-$'\037']/}"
    description="${description//\"/\'}"
    printf '%s' "${description}"
}

escape_conf_string() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "${value}"
}

normalize_audio_position() {
    local position="$1"
    position="${position//\[/}"
    position="${position//\]/}"
    position="${position//\"/}"
    position="${position// /}"
    position="${position//;/,}"

    if [[ -z "${position}" ]]; then
        position="FL,FR"
    fi

    printf '%s' "${position}"
}

audio_position_conf_list() {
    local position
    position="$(normalize_audio_position "$1")"
    printf '%s' "${position//,/ }"
}

channel_count_from_positions() {
    local position
    local -a channels=()

    position="$(normalize_audio_position "$1")"
    local IFS=','
    read -r -a channels <<< "${position}"
    printf '%s' "${#channels[@]}"
}

extract_first_numeric_id() {
    sed -nE '
        s/.*\bid[[:space:]]+([0-9]+)\b.*/\1/p
        t
        s/^[[:space:]]*([0-9]+)[[:space:]]*$/\1/p
    ' | head -n 1
}

validate_sink_name() {
    local name="$1"
    [[ "${name}" =~ ^[a-zA-Z0-9_-]+$ ]]
}

validate_port() {
    local port="$1"
    [[ "${port}" =~ ^[0-9]+$ ]] && (( port >= 1024 && port <= 65535 ))
}

validate_ip() {
    local ip="$1"
    local octet='(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)'
    [[ "${ip}" =~ ^${octet}\.${octet}\.${octet}\.${octet}$ ]]
}

port_in_use() {
    local port="$1"

    ss -H -ltnu 2>/dev/null | awk -v port="${port}" '
        {
            local_addr = $4
            if (local_addr ~ ":" port "$") {
                found = 1
                exit
            }
        }
        END { exit(found ? 0 : 1) }
    '
}

node_exists() {
    local node_id="$1"
    pw-cli info "${node_id}" >/dev/null 2>&1
}

module_exists() {
    local module_id="$1"
    pw-cli info "${module_id}" >/dev/null 2>&1
}

get_node_property_by_id() {
    local node_id="$1"
    local property_name="$2"

    pw-dump 2>/dev/null | jq -r \
        --argjson node_id "${node_id}" \
        --arg property_name "${property_name}" \
        '.[]
         | select(.type == "PipeWire:Interface:Node" and .id == $node_id)
         | .info.props[$property_name] // empty' \
        2>/dev/null | head -n 1
}

virtual_sink_name_exists() {
    local node_name="$1"

    pw-dump 2>/dev/null | jq -e \
        --arg node_name "${node_name}" \
        '.[]
         | select(
             .type == "PipeWire:Interface:Node"
             and (.info.props["node.name"] // "") == $node_name
           )' >/dev/null 2>&1
}

get_virtual_sinks_json() {
    pw-dump 2>/dev/null | jq -c '
        [
          .[]
          | select(
              .type == "PipeWire:Interface:Node"
              and .info.props["media.class"] == "Audio/Sink"
              and (.info.props["node.name"] // "" | test("^virtual_"))
            )
          | {
              id: .id,
              name: (.info.props["node.name"] // "unknown"),
              description: (.info.props["node.description"] // "unknown"),
              audio_position: (.info.props["audio.position"] // "FL,FR")
            }
        ]
    ' 2>/dev/null || printf '[]\n'
}

get_volume_state() {
    local target="$1"
    local output=""
    local volume="N/A"
    local mute="false"

    output="$(wpctl get-volume "${target}" 2>/dev/null || true)"

    if [[ -n "${output}" && "${output}" =~ ([0-9]+(\.[0-9]+)?) ]]; then
        volume="${BASH_REMATCH[1]}"
    fi

    if [[ "${output}" == *"[MUTED]"* ]]; then
        mute="true"
    fi

    printf '%s\t%s\n' "${volume}" "${mute}"
}

volume_to_percent_label() {
    local volume="$1"

    if [[ "${volume}" == "N/A" ]]; then
        printf 'N/A'
    else
        printf '%.0f%%' "$(echo "${volume} * 100" | bc -l)"
    fi
}

get_current_volume_float() {
    local target="$1"
    local volume_state=""

    volume_state="$(get_volume_state "${target}")"
    printf '%s' "${volume_state%%$'\t'*}"
}

clamp_volume_float() {
    local value="$1"

    if (( $(echo "${value} < 0" | bc -l) )); then
        printf '0.0'
    elif (( $(echo "${value} > 1.0" | bc -l) )); then
        printf '1.0'
    else
        echo "scale=4; ${value}/1" | bc -l
    fi
}

load_runtime_state() {
    local node_id=""
    local module_id=""
    local proto=""
    local addr=""
    local port=""

    ensure_runtime_dirs

    if [[ ! -f "${RUNTIME_STATE_FILE}" ]]; then
        return 0
    fi

    while IFS=$'\t' read -r node_id module_id proto addr port; do
        [[ -n "${node_id}" && -n "${module_id}" ]] || continue
        STREAM_MODULE_ID["${node_id}"]="${module_id}"
        STREAM_PROTO["${node_id}"]="${proto}"
        STREAM_ADDR["${node_id}"]="${addr}"
        STREAM_PORT["${node_id}"]="${port}"
    done < "${RUNTIME_STATE_FILE}"

    prune_runtime_state
}

save_runtime_state() {
    local tmp_file=""
    local node_id=""

    ensure_runtime_dirs
    tmp_file="$(mktemp "${STATE_DIR}/runtime-streams.tsv.XXXXXX")"

    {
        for node_id in "${!STREAM_MODULE_ID[@]}"; do
            printf '%s\t%s\t%s\t%s\t%s\n' \
                "${node_id}" \
                "${STREAM_MODULE_ID[${node_id}]}" \
                "${STREAM_PROTO[${node_id}]}" \
                "${STREAM_ADDR[${node_id}]}" \
                "${STREAM_PORT[${node_id}]}"
        done
    } | sort -n > "${tmp_file}"

    mv "${tmp_file}" "${RUNTIME_STATE_FILE}"
}

prune_runtime_state() {
    local changed=0
    local node_id=""

    for node_id in "${!STREAM_MODULE_ID[@]}"; do
        if ! node_exists "${node_id}" || ! module_exists "${STREAM_MODULE_ID[${node_id}]}"; then
            unset 'STREAM_MODULE_ID[$node_id]' 'STREAM_PROTO[$node_id]' 'STREAM_ADDR[$node_id]' 'STREAM_PORT[$node_id]'
            changed=1
        fi
    done

    if (( changed )); then
        save_runtime_state
    fi
}

track_stream() {
    local node_id="$1"
    local module_id="$2"
    local proto="$3"
    local addr="$4"
    local port="$5"

    STREAM_MODULE_ID["${node_id}"]="${module_id}"
    STREAM_PROTO["${node_id}"]="${proto}"
    STREAM_ADDR["${node_id}"]="${addr}"
    STREAM_PORT["${node_id}"]="${port}"

    save_runtime_state
}

untrack_stream() {
    local node_id="$1"

    unset 'STREAM_MODULE_ID[$node_id]' 'STREAM_PROTO[$node_id]' 'STREAM_ADDR[$node_id]' 'STREAM_PORT[$node_id]'
    save_runtime_state
}

load_pipewire_module() {
    local module_name="$1"
    local module_args="$2"
    local log_file="$3"
    local output=""
    local module_id=""

    if ! output="$(pw-cli load-module "${module_name}" "${module_args}" 2>&1)"; then
        printf '%s\n' "${output}" > "${log_file}"
        return 1
    fi

    printf '%s\n' "${output}" > "${log_file}"
    module_id="$(printf '%s\n' "${output}" | extract_first_numeric_id || true)"

    if [[ -z "${module_id}" ]]; then
        return 1
    fi

    printf '%s' "${module_id}"
}

print_sink_table() {
    local sinks_json=""
    local count=0

    prune_runtime_state
    sinks_json="$(get_virtual_sinks_json)"
    count="$(printf '%s\n' "${sinks_json}" | jq 'length')"

    printf '%b\n' "${BOLD}${BLUE}Active Virtual Sinks${RESET}"
    printf '%b\n' '──────────────────────────────────────────────────────────────────────────────────────────'
    printf '  %-6s %-28s %-22s %-8s %-8s %-26s\n' \
        'ID' 'Name' 'Description' 'Volume' 'Mute' 'Network Stream'
    printf '%b\n' '──────────────────────────────────────────────────────────────────────────────────────────'

    if [[ "${count}" -eq 0 ]]; then
        printf '%b\n' "  ${YELLOW}(no virtual sinks found)${RESET}"
        printf '%b\n' '──────────────────────────────────────────────────────────────────────────────────────────'
        return 0
    fi

    while IFS= read -r sink; do
        local id=""
        local name=""
        local description=""
        local volume_state=""
        local volume=""
        local mute=""
        local mute_label=""
        local stream_label='-'

        id="$(printf '%s\n' "${sink}" | jq -r '.id')"
        name="$(printf '%s\n' "${sink}" | jq -r '.name')"
        description="$(printf '%s\n' "${sink}" | jq -r '.description')"

        volume_state="$(get_volume_state "${id}")"
        volume="${volume_state%%$'\t'*}"
        mute="${volume_state##*$'\t'}"

        volume="$(volume_to_percent_label "${volume}")"
        if [[ "${mute}" == "true" ]]; then
            mute_label="${RED}MUTED${RESET}"
        else
            mute_label="${GREEN}live${RESET}"
        fi

        if [[ -n "${STREAM_MODULE_ID[${id}]+x}" ]]; then
            stream_label="${CYAN}${STREAM_PROTO[${id}]}://${STREAM_ADDR[${id}]}:${STREAM_PORT[${id}]}${RESET}"
        fi

        printf '  %-6s %-28s %-22s %-8s %-12b %-26b\n' \
            "${id}" "${name}" "${description}" "${volume}" "${mute_label}" "${stream_label}"
    done < <(printf '%s\n' "${sinks_json}" | jq -c '.[]')

    printf '%b\n' '──────────────────────────────────────────────────────────────────────────────────────────'
}

# ---------------------------------------------------------------------------
# Dependency and service checks
# ---------------------------------------------------------------------------
check_dependencies() {
    local -a required_bins=(pipewire wireplumber pw-cli pw-dump wpctl jq bc ss)
    local -a missing=()
    local bin=""

    for bin in "${required_bins[@]}"; do
        if ! command -v "${bin}" >/dev/null 2>&1; then
            missing+=("${bin}")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required binaries: ${missing[*]}"
        printf '%b\n' "  Install them with your package manager, for example:"
        printf '%b\n' "  ${CYAN}sudo apt install pipewire wireplumber pipewire-bin jq bc iproute2${RESET}"
        exit 1
    fi
}

check_services() {
    local -a services=(pipewire wireplumber)
    local service_name=""

    for service_name in "${services[@]}"; do
        if ! systemctl --user is-active --quiet "${service_name}"; then
            error "User service '${service_name}' is not active."
            printf '%b\n' "  Start it with: ${CYAN}systemctl --user start ${service_name}${RESET}"
            systemctl --user status "${service_name}" --no-pager --lines=5 || true
            exit 1
        fi
    done
}

# ---------------------------------------------------------------------------
# Virtual sink CRUD
# ---------------------------------------------------------------------------
create_virtual_sink() {
    local sink_name=""
    local node_name=""
    local description=""
    local channel_choice=""
    local audio_position=""
    local audio_channels=""
    local output=""
    local node_id=""

    printf '\n%b\n' "${BOLD}Create Virtual Audio Sink${RESET}"

    while true; do
        prompt_input sink_name "  Sink name (letters, digits, _ or -, no spaces): "
        if ! validate_sink_name "${sink_name}"; then
            warn "Invalid name. Use only letters, digits, underscores, or hyphens."
            continue
        fi

        node_name="virtual_${sink_name}"
        if virtual_sink_name_exists "${node_name}"; then
            warn "A virtual sink named '${node_name}' already exists. Choose another name."
            continue
        fi

        break
    done

    prompt_input description "  Description (shown in volume applets): " "${node_name}"
    description="$(sanitize_description "${description}")"
    if [[ -z "${description}" ]]; then
        description="${node_name}"
    fi

    printf '%s\n' '  Channel map options:'
    printf '%s\n' '    1) Stereo (FL,FR)  [default]'
    printf '%s\n' '    2) Mono   (MONO)'
    printf '%s\n' '    3) 5.1    (FL,FR,FC,LFE,SL,SR)'
    prompt_input channel_choice "  Choice" '1'

    case "${channel_choice}" in
        2) audio_position='MONO' ;;
        3) audio_position='FL,FR,FC,LFE,SL,SR' ;;
        *) audio_position='FL,FR' ;;
    esac

    audio_channels="$(channel_count_from_positions "${audio_position}")"

    # Required DE visibility properties:
    #   media.class=Audio/Sink        -> makes the node visible to desktop mixers
    #   node.description="..."       -> human-friendly label in GUIs
    #   audio.position=[ FL FR ... ]  -> standard channel map for routing
    if ! output="$(
        pw-cli create-node adapter \
            "{ \
                factory.name=support.null-audio-sink \
                node.name=\"${node_name}\" \
                node.description=\"${description}\" \
                media.class=Audio/Sink \
                audio.channels=${audio_channels} \
                audio.position=[ ${audio_position//,/ } ] \
                node.virtual=true \
                monitor.channel-volumes=true \
                object.linger=true \
            }" 2>&1
    )"; then
        error "Failed to create the virtual sink."
        printf '%s\n' "${output}"
        return 1
    fi

    node_id="$(printf '%s\n' "${output}" | extract_first_numeric_id || true)"
    if [[ -z "${node_id}" || ! node_exists "${node_id}" ]]; then
        error "PipeWire did not return a usable node ID for the new sink."
        printf '%s\n' "${output}"
        return 1
    fi

    success "Virtual sink '${node_name}' created with Node ID ${node_id}."
    printf '  Description : %s\n' "${description}"
    printf '  Channel map : %s\n' "${audio_position}"
    printf '%b\n' "  ${YELLOW}Tip:${RESET} It should now appear in pavucontrol and desktop volume applets."
}

delete_virtual_sink() {
    local node_id=""

    printf '\n%b\n' "${BOLD}Delete Virtual Audio Sink${RESET}"
    print_sink_table
    prompt_input node_id "  Enter Node ID to delete (blank to cancel): "

    if [[ -z "${node_id}" ]]; then
        return 0
    fi

    if ! node_exists "${node_id}"; then
        error "Node ID ${node_id} does not exist."
        return 1
    fi

    if ! confirm_action "  Destroy node ${node_id}?"; then
        info "Cancelled."
        return 0
    fi

    if [[ -n "${STREAM_MODULE_ID[${node_id}]+x}" ]]; then
        _stop_stream "${node_id}"
    fi

    if ! pw-cli destroy "${node_id}" >/dev/null 2>&1; then
        error "Failed to destroy node ${node_id}."
        return 1
    fi

    success "Node ${node_id} destroyed."
}

# ---------------------------------------------------------------------------
# Volume control
# ---------------------------------------------------------------------------
set_target_volume_float() {
    local target="$1"
    local volume="$2"

    wpctl set-volume "${target}" "${volume}"
}

volume_control() {
    local target=""
    local action=""
    local current_volume=""
    local new_volume=""
    local percentage=""

    printf '\n%b\n' "${BOLD}Volume Control${RESET}"
    print_sink_table

    prompt_input target "  Node ID or '@DEFAULT_AUDIO_SINK@'" '@DEFAULT_AUDIO_SINK@'

    if [[ "${target}" =~ ^[0-9]+$ ]] && ! node_exists "${target}"; then
        error "Node ID ${target} does not exist."
        return 1
    fi

    printf '%s\n' '  Volume actions:'
    printf '%s\n' '    1) Increase by 5%'
    printf '%s\n' '    2) Decrease by 5%'
    printf '%s\n' '    3) Set absolute value'
    printf '%s\n' '    4) Toggle mute'
    prompt_input action "  Choice: "

    case "${action}" in
        1)
            current_volume="$(get_current_volume_float "${target}")"
            if [[ -z "${current_volume}" || "${current_volume}" == "N/A" ]]; then
                error "Unable to read the current volume for '${target}'."
                return 1
            fi
            new_volume="$(echo "${current_volume} + 0.05" | bc -l)"
            new_volume="$(clamp_volume_float "${new_volume}")"
            set_target_volume_float "${target}" "${new_volume}"
            success "Volume set to $(volume_to_percent_label "${new_volume}")."
            ;;
        2)
            current_volume="$(get_current_volume_float "${target}")"
            if [[ -z "${current_volume}" || "${current_volume}" == "N/A" ]]; then
                error "Unable to read the current volume for '${target}'."
                return 1
            fi
            new_volume="$(echo "${current_volume} - 0.05" | bc -l)"
            new_volume="$(clamp_volume_float "${new_volume}")"
            set_target_volume_float "${target}" "${new_volume}"
            success "Volume set to $(volume_to_percent_label "${new_volume}")."
            ;;
        3)
            prompt_input percentage "  Target volume percentage (0-100): "
            if [[ ! "${percentage}" =~ ^[0-9]+$ ]] || (( percentage < 0 || percentage > 100 )); then
                error "Invalid percentage. Must be 0 through 100."
                return 1
            fi
            new_volume="$(echo "scale=4; ${percentage}/100" | bc -l)"
            new_volume="$(clamp_volume_float "${new_volume}")"
            set_target_volume_float "${target}" "${new_volume}"
            success "Volume set to ${percentage}%."
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
# Network streaming
# ---------------------------------------------------------------------------
_start_tcp_stream() {
    local node_id="$1"
    local node_name="$2"
    local audio_position="$3"
    local addr="$4"
    local port="$5"
    local audio_channels=""
    local audio_position_list=""
    local module_args=""
    local module_id=""
    local log_file=""

    audio_channels="$(channel_count_from_positions "${audio_position}")"
    audio_position_list="$(audio_position_conf_list "${audio_position}")"
    log_file="${LOG_DIR}/stream-${node_id}-tcp.log"

    # Official PipeWire protocol-simple properties:
    #   capture=true                 -> expose a capture server
    #   capture.node="name"         -> capture from the selected node
    #   stream.capture.sink=true     -> capture the sink monitor ports
    #   server.address=[ ... ]       -> bind TCP listener for clients
    module_args="{ \
        capture=true \
        playback=false \
        capture.node=\"${node_name}\" \
        server.address=[ \"tcp:${addr}:${port}\" ] \
        audio.format=S16LE \
        audio.rate=48000 \
        audio.channels=${audio_channels} \
        audio.position=[ ${audio_position_list} ] \
        stream.capture.sink=true \
        node.name=\"virtual-audio-tcp-${node_id}\" \
        node.description=\"TCP stream for ${node_name}\" \
        node.virtual=true \
    }"

    if ! module_id="$(load_pipewire_module "libpipewire-module-protocol-simple" "${module_args}" "${log_file}")"; then
        error "TCP stream failed to start. See ${log_file}"
        return 1
    fi

    if ! module_exists "${module_id}"; then
        error "TCP stream module ${module_id} did not remain loaded. See ${log_file}"
        return 1
    fi

    track_stream "${node_id}" "${module_id}" 'tcp' "${addr}" "${port}"
    success "TCP stream started: tcp://${addr}:${port} (module ${module_id})"
    printf '%b\n' "  Connect with ffplay: ${CYAN}ffplay -f s16le -ar 48000 -ac ${audio_channels} tcp://${addr}:${port}${RESET}"
    printf '%b\n' "  Connect with VLC:    ${CYAN}vlc tcp://${addr}:${port}${RESET}"
}

_start_rtp_stream() {
    local node_id="$1"
    local node_name="$2"
    local audio_position="$3"
    local addr="$4"
    local port="$5"
    local audio_channels=""
    local audio_position_list=""
    local module_args=""
    local module_id=""
    local log_file=""

    audio_channels="$(channel_count_from_positions "${audio_position}")"
    audio_position_list="$(audio_position_conf_list "${audio_position}")"
    log_file="${LOG_DIR}/stream-${node_id}-rtp.log"

    # Official PipeWire RTP sink properties:
    #   destination.ip / destination.port -> network endpoint
    #   stream.props.target.object        -> bind stream to the chosen sink
    #   stream.capture.sink=true          -> capture the sink monitor ports
    module_args="{ \
        destination.ip=\"${addr}\" \
        destination.port=${port} \
        sess.name=\"${node_name} RTP stream\" \
        sess.media=\"audio\" \
        audio.format=S16BE \
        audio.rate=48000 \
        audio.channels=${audio_channels} \
        audio.position=[ ${audio_position_list} ] \
        node.name=\"virtual-audio-rtp-${node_id}\" \
        node.description=\"RTP stream for ${node_name}\" \
        node.virtual=true \
        stream.props={ \
            target.object=\"${node_name}\" \
            stream.capture.sink=true \
            node.name=\"virtual-audio-rtp-stream-${node_id}\" \
        } \
    }"

    if ! module_id="$(load_pipewire_module "libpipewire-module-rtp-sink" "${module_args}" "${log_file}")"; then
        error "RTP stream failed to start. See ${log_file}"
        return 1
    fi

    if ! module_exists "${module_id}"; then
        error "RTP stream module ${module_id} did not remain loaded. See ${log_file}"
        return 1
    fi

    track_stream "${node_id}" "${module_id}" 'rtp' "${addr}" "${port}"
    success "RTP stream started: rtp://${addr}:${port} (module ${module_id})"
    printf '%b\n' "  Connect with VLC: ${CYAN}vlc rtp://@:${port}${RESET}"
}

_stop_stream() {
    local node_id="$1"
    local module_id=""

    if [[ -z "${STREAM_MODULE_ID[${node_id}]+x}" ]]; then
        warn "No tracked stream found for node ${node_id}."
        return 1
    fi

    module_id="${STREAM_MODULE_ID[${node_id}]}"
    if module_exists "${module_id}"; then
        if ! pw-cli destroy "${module_id}" >/dev/null 2>&1; then
            error "Failed to unload stream module ${module_id}."
            return 1
        fi
    fi

    untrack_stream "${node_id}"
    success "Stream for node ${node_id} stopped."
}

expose_sink_network() {
    local node_id=""
    local protocol_choice=""
    local protocol='tcp'
    local addr=""
    local port=""
    local node_name=""
    local audio_position=""

    printf '\n%b\n' "${BOLD}Expose Virtual Sink to Network${RESET}"
    print_sink_table

    prompt_input node_id "  Node ID to stream: "
    if [[ -z "${node_id}" ]]; then
        return 0
    fi

    if ! node_exists "${node_id}"; then
        error "Node ID ${node_id} does not exist."
        return 1
    fi

    if [[ -n "${STREAM_MODULE_ID[${node_id}]+x}" ]]; then
        warn "Node ${node_id} is already streaming on port ${STREAM_PORT[${node_id}]}."
        if ! confirm_action '  Stop the current stream and reconfigure it?'; then
            return 0
        fi
        _stop_stream "${node_id}"
    fi

    printf '%s\n' '  Streaming protocol:'
    printf '%s\n' '    1) TCP  (protocol-simple, compatible with ffplay/VLC raw PCM)'
    printf '%s\n' '    2) RTP  (compatible with VLC and GStreamer)'
    prompt_input protocol_choice '  Choice' '1'
    case "${protocol_choice}" in
        2) protocol='rtp' ;;
        *) protocol='tcp' ;;
    esac

    prompt_input addr '  Target IP address' '127.0.0.1'
    if ! validate_ip "${addr}"; then
        error "Invalid IPv4 address: ${addr}"
        return 1
    fi

    prompt_input port '  Port' '8080'
    if ! validate_port "${port}"; then
        error "Invalid port. Must be an integer between 1024 and 65535."
        return 1
    fi

    if port_in_use "${port}"; then
        error "Port ${port} is already in use on this system."
        return 1
    fi

    node_name="$(get_node_property_by_id "${node_id}" 'node.name')"
    audio_position="$(get_node_property_by_id "${node_id}" 'audio.position')"

    if [[ -z "${node_name}" ]]; then
        error "Failed to resolve PipeWire node.name for node ${node_id}."
        return 1
    fi

    audio_position="$(normalize_audio_position "${audio_position}")"

    if [[ "${protocol}" == 'tcp' ]]; then
        _start_tcp_stream "${node_id}" "${node_name}" "${audio_position}" "${addr}" "${port}"
    else
        _start_rtp_stream "${node_id}" "${node_name}" "${audio_position}" "${addr}" "${port}"
    fi
}

update_stream_port() {
    local node_id=""
    local new_port=""
    local node_name=""
    local audio_position=""
    local protocol=""
    local addr=""

    printf '\n%b\n' "${BOLD}Update Network Stream Port${RESET}"
    print_sink_table

    prompt_input node_id '  Node ID whose stream port to update: '
    if [[ -z "${node_id}" ]]; then
        return 0
    fi

    if [[ -z "${STREAM_MODULE_ID[${node_id}]+x}" ]]; then
        error "Node ${node_id} is not currently streaming."
        return 1
    fi

    if ! node_exists "${node_id}"; then
        error "Node ${node_id} no longer exists."
        return 1
    fi

    prompt_input new_port '  New port' "${STREAM_PORT[${node_id}]}"
    if ! validate_port "${new_port}"; then
        error "Invalid port. Must be an integer between 1024 and 65535."
        return 1
    fi

    if [[ "${new_port}" == "${STREAM_PORT[${node_id}]}" ]]; then
        info "The stream is already using port ${new_port}."
        return 0
    fi

    if port_in_use "${new_port}"; then
        error "Port ${new_port} is already in use on this system."
        return 1
    fi

    protocol="${STREAM_PROTO[${node_id}]}"
    addr="${STREAM_ADDR[${node_id}]}"
    node_name="$(get_node_property_by_id "${node_id}" 'node.name')"
    audio_position="$(normalize_audio_position "$(get_node_property_by_id "${node_id}" 'audio.position')")"

    _stop_stream "${node_id}"

    if [[ "${protocol}" == 'tcp' ]]; then
        _start_tcp_stream "${node_id}" "${node_name}" "${audio_position}" "${addr}" "${new_port}"
    else
        _start_rtp_stream "${node_id}" "${node_name}" "${audio_position}" "${addr}" "${new_port}"
    fi
}

stop_stream_menu() {
    local node_id=""

    printf '\n%b\n' "${BOLD}Stop Network Stream${RESET}"
    print_sink_table
    prompt_input node_id '  Node ID to stop streaming: '

    if [[ -z "${node_id}" ]]; then
        return 0
    fi

    _stop_stream "${node_id}"
}

# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------
save_config() {
    local sinks_json=""
    local count=0
    local tmp_file=""
    local sink=""

    printf '\n%b\n' "${BOLD}Save Configuration${RESET}"

    prune_runtime_state
    sinks_json="$(get_virtual_sinks_json)"
    count="$(printf '%s\n' "${sinks_json}" | jq 'length')"

    if [[ "${count}" -eq 0 ]]; then
        warn 'No virtual sinks are active. Nothing to save.'
        return 0
    fi

    ensure_runtime_dirs
    tmp_file="$(mktemp "${CONFIG_DIR}/virtual-audio-cards.conf.tmp.XXXXXX")"

    {
        cat <<'EOF'
# =============================================================================
# virtual-audio-cards.conf
# Generated by virtual-audio-manager.sh
#
# Third-party GUIs / Web UIs can parse the following comment keys:
#   # stream.<node_name>.protocol=<tcp|rtp>
#   # stream.<node_name>.address=<ipv4>
#   # stream.<node_name>.port=<port>
# =============================================================================

context.modules = [
EOF

        while IFS= read -r sink; do
            local id=""
            local name=""
            local description=""
            local description_escaped=""
            local audio_position=""
            local audio_channels=""

            id="$(printf '%s\n' "${sink}" | jq -r '.id')"
            name="$(printf '%s\n' "${sink}" | jq -r '.name')"
            description="$(printf '%s\n' "${sink}" | jq -r '.description')"
            audio_position="$(normalize_audio_position "$(printf '%s\n' "${sink}" | jq -r '.audio_position')")"
            audio_channels="$(channel_count_from_positions "${audio_position}")"
            description_escaped="$(escape_conf_string "${description}")"

            printf '  # Virtual sink: %s\n' "${name}"
            printf '  # Description: %s\n' "${description}"

            if [[ -n "${STREAM_MODULE_ID[${id}]+x}" ]]; then
                printf '  # stream.%s.protocol=%s\n' "${name}" "${STREAM_PROTO[${id}]}"
                printf '  # stream.%s.address=%s\n' "${name}" "${STREAM_ADDR[${id}]}"
                printf '  # stream.%s.port=%s\n' "${name}" "${STREAM_PORT[${id}]}"
            fi

            cat <<NODEBLOCK
  {   name = libpipewire-module-adapter
      args = {
          factory.name            = support.null-audio-sink
          node.name               = "${name}"
          node.description        = "${description_escaped}"
          media.class             = Audio/Sink
          audio.channels          = ${audio_channels}
          audio.position          = [ $(audio_position_conf_list "${audio_position}") ]
          node.virtual            = true
          monitor.channel-volumes = true
          object.linger           = true
      }
  }
NODEBLOCK
        done < <(printf '%s\n' "${sinks_json}" | jq -c '.[]')

        printf ']\n'
    } > "${tmp_file}"

    if [[ ! -s "${tmp_file}" ]]; then
        rm -f "${tmp_file}"
        error 'Config generation produced an empty file. Save aborted.'
        return 1
    fi

    mv "${tmp_file}" "${CONFIG_FILE}"
    success "Configuration saved to ${CONFIG_FILE}"
    printf '%b\n' "  ${YELLOW}Reload with:${RESET} systemctl --user restart pipewire wireplumber"
}

# ---------------------------------------------------------------------------
# Dashboard / TUI
# ---------------------------------------------------------------------------
print_header() {
    if command -v clear >/dev/null 2>&1; then
        clear
    else
        printf '\033c'
    fi

    printf '%b\n' "${BOLD}${BLUE}"
    printf '%s\n' '  ╔════════════════════════════════════════════════════════════════════════════╗'
    printf '%s\n' '  ║      Virtual Audio Card Manager — Native PipeWire / WirePlumber           ║'
    printf '%s\n' '  ╚════════════════════════════════════════════════════════════════════════════╝'
    printf '%b\n' "${RESET}"
    print_sink_table
    printf '\n'
}

main_menu() {
    local choice=""

    while true; do
        print_header
        printf '%b\n' "${BOLD}Menu${RESET}"
        printf '%s\n' '  1) Create virtual sink'
        printf '%s\n' '  2) Delete virtual sink'
        printf '%s\n' '  3) Volume control'
        printf '%s\n' '  4) Expose sink to network (TCP/RTP)'
        printf '%s\n' '  5) Update stream port'
        printf '%s\n' '  6) Stop stream'
        printf '%s\n' "  7) Save config to ${CONFIG_FILE}"
        printf '%s\n' '  h) Help / one-line launch info'
        printf '%s\n' '  q) Quit'
        printf '\n'

        prompt_input choice '  Choice: '

        case "${choice}" in
            1) create_virtual_sink ;;
            2) delete_virtual_sink ;;
            3) volume_control ;;
            4) expose_sink_network ;;
            5) update_stream_port ;;
            6) stop_stream_menu ;;
            7) save_config ;;
            h|H) printf '\n'; show_usage ;;
            q|Q) printf '\n%b\n' "${GREEN}Goodbye.${RESET}"; exit 0 ;;
            *) warn "Unknown option: ${choice}" ;;
        esac

        printf '\n'
        pause_for_user
    done
}

parse_args() {
    if [[ $# -eq 0 ]]; then
        return 0
    fi

    case "$1" in
        -h|--help)
            show_usage
            exit 0
            ;;
        -V|--version)
            printf '%s\n' "${VERSION}"
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
}

main() {
    parse_args "$@"
    setup_terminal_io
    ensure_runtime_dirs
    load_runtime_state
    check_dependencies
    check_services
    main_menu
}

main "$@"

#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="${0##*/}"
readonly DEFAULT_OUTPUT_PATH=".wslconfig"

output_path="$DEFAULT_OUTPUT_PATH"
kernel_path=""
memory_value=""
num_processors=""
swap_size=""
swapfile_path=""
gui_applications="true"
debug_console="false"
nested_virtualization="true"
vm_idle_timeout_seconds="60"
auto_memory_reclaim="gradual"
networking_mode="nat"
dns_tunneling="true"
dns_proxy="true"
firewall="true"
sparse_vhd="false"
auto_proxy="true"
total_memory_gb=""
logical_processors=""
pwsh_path=""

show_help() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Generate a Windows .wslconfig file using detected host hardware values or
explicit overrides.

Options:
  -h, --help                            Show this help text.
  -e, --examples                        Print example values and exit.
  -o, --output <path>                   Output file path. Default: ${DEFAULT_OUTPUT_PATH}
  -k, --kernel <path>                   Windows or WSL path to vmlinux.
  -f, --swapfile <path>                 Windows or WSL path to the swap VHDX file.
  -m, --memory <size>                   Memory limit. Accepts 24 or 24GB or 24576MB.
  -s, --swap <size>                     Swap size. Accepts 8 or 8GB or 8192MB.
  -p, --processors <count>              Processor count.
  -t, --vm-idle-timeout <seconds>       Idle timeout in seconds. Default: 60.
  -d, --debug-console <true|false>      Enable debug console.
  -g, --gui-applications <true|false>   Enable WSLg GUI support.
  -n, --nested-virtualization <true|false>
                                        Enable nested virtualization.
      --auto-memory-reclaim <mode>      disabled, gradual, dropCache
      --networking-mode <mode>          nat, mirrored, bridged, none, virtioproxy
      --dns-tunneling <true|false>      Enable DNS tunneling.
      --dns-proxy <true|false>          Configure DNS proxy when using NAT.
      --firewall <true|false>           Let Windows Firewall filter WSL traffic.
      --sparse-vhd <true|false>         Create new VHDs as sparse files.
      --auto-proxy <true|false>         Import Windows proxy settings into WSL.

Examples:
  ${SCRIPT_NAME} --kernel 'C:\\Users\\me\\WSL2\\vmlinux' --memory 24 --processors 8
  ${SCRIPT_NAME} --kernel /mnt/c/Users/me/WSL2/vmlinux --swapfile /mnt/c/Temp/swap.vhdx
EOF
}

show_examples() {
    cat <<'EOF'
Example values:
  kernel="C:\\Users\\me\\WSL2\\vmlinux"
  memory="24GB"
  processors="8"
  swap="8GB"
  swapfile="C:\\Users\\me\\AppData\\Local\\Temp\\swap.vhdx"
  guiApplications="true"
  debugConsole="false"
  nestedVirtualization="true"
  vmIdleTimeout="60000"
  networkingMode="nat"
  dnsTunneling="true"
  dnsProxy="true"
  firewall="true"
  autoProxy="true"
  autoMemoryReclaim="gradual"
  sparseVhd="false"
EOF
}

fail() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

normalize_boolean() {
    local value=${1,,}

    case "$value" in
        true|false)
            printf '%s\n' "$value"
            ;;
        *)
            fail "Invalid boolean value: $1"
            ;;
    esac
}

normalize_size() {
    local value=${1^^}

    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%sGB\n' "$value"
        return
    fi

    if [[ "$value" =~ ^[0-9]+(GB|MB)$ ]]; then
        printf '%s\n' "$value"
        return
    fi

    fail "Invalid size value: $1. Use values like 24, 24GB, or 24576MB."
}

validate_non_negative_integer() {
    local value=$1
    local label=$2

    [[ "$value" =~ ^[0-9]+$ ]] || fail "${label} must be a non-negative integer."
}

validate_positive_integer() {
    local value=$1
    local label=$2

    validate_non_negative_integer "$value" "$label"
    (( value > 0 )) || fail "${label} must be greater than zero."
}

normalize_windows_path() {
    local raw_path=$1
    local windows_path=$raw_path

    if [[ "$raw_path" == /* ]] && command_exists wslpath; then
        windows_path="$(wslpath -w "$raw_path" 2>/dev/null || true)"
        if [[ -z "$windows_path" ]]; then
            windows_path="$raw_path"
        fi
    fi

    windows_path="${windows_path//\//\\}"
    printf '%s\n' "$windows_path" | sed -E 's#\\+#\\\\#g'
}

find_powershell() {
    if command_exists powershell.exe; then
        pwsh_path="$(command -v powershell.exe)"
        return
    fi

    if [[ -x "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" ]]; then
        pwsh_path="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
        return
    fi

    if [[ -x "/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" ]]; then
        pwsh_path="/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
        return
    fi

    fail "Unable to locate powershell.exe. Run this script from WSL on a Windows host."
}

run_powershell() {
    "$pwsh_path" -NoLogo -NoProfile -NonInteractive -Command "$1" | tr -d '\r'
}

detect_windows_specs() {
    find_powershell

    if [[ -z "$total_memory_gb" ]]; then
        local total_memory_bytes
        total_memory_bytes="$(run_powershell '(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory')"
        [[ "$total_memory_bytes" =~ ^[0-9]+$ ]] || fail "Failed to detect Windows physical memory."
        total_memory_gb=$(( total_memory_bytes / 1024 / 1024 / 1024 ))
        (( total_memory_gb > 0 )) || fail "Detected Windows physical memory is invalid."
    fi

    if [[ -z "$logical_processors" ]]; then
        logical_processors="$(run_powershell '(Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors')"
        [[ "$logical_processors" =~ ^[0-9]+$ ]] || fail "Failed to detect the number of Windows logical processors."
    fi
}

recommend_memory_size() {
    local recommended=$(( total_memory_gb / 2 ))

    if (( recommended < 2 )); then
        recommended=2
    fi

    printf '%sGB\n' "$recommended"
}

recommend_swap_size() {
    local recommended=$(( (total_memory_gb + 3) / 4 ))

    if (( recommended < 1 )); then
        recommended=1
    fi

    printf '%sGB\n' "$recommended"
}

normalize_networking_mode() {
    local mode=${1,,}

    case "$mode" in
        nat|mirrored|bridged|none|virtioproxy)
            printf '%s\n' "$mode"
            ;;
        *)
            fail "Invalid networking mode: $1"
            ;;
    esac
}

normalize_auto_memory_reclaim() {
    case "${1,,}" in
        disabled|gradual)
            printf '%s\n' "${1,,}"
            ;;
        dropcache)
            printf '%s\n' "dropCache"
            ;;
        *)
            fail "Invalid auto memory reclaim mode: $1"
            ;;
    esac
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -e|--examples)
                show_examples
                exit 0
                ;;
            -o|--output)
                [[ $# -ge 2 ]] || fail "Missing value for $1."
                output_path="$2"
                shift 2
                ;;
            -k|--kernel)
                [[ $# -ge 2 ]] || fail "Missing value for $1."
                kernel_path="$(normalize_windows_path "$2")"
                shift 2
                ;;
            -f|--swapfile)
                [[ $# -ge 2 ]] || fail "Missing value for $1."
                swapfile_path="$(normalize_windows_path "$2")"
                shift 2
                ;;
            -m|--memory)
                [[ $# -ge 2 ]] || fail "Missing value for $1."
                memory_value="$(normalize_size "$2")"
                shift 2
                ;;
            -s|--swap)
                [[ $# -ge 2 ]] || fail "Missing value for $1."
                swap_size="$(normalize_size "$2")"
                shift 2
                ;;
            -p|--processors)
                [[ $# -ge 2 ]] || fail "Missing value for $1."
                validate_positive_integer "$2" "Processor count"
                num_processors="$2"
                shift 2
                ;;
            -t|--vm-idle-timeout)
                [[ $# -ge 2 ]] || fail "Missing value for $1."
                validate_non_negative_integer "$2" "VM idle timeout"
                vm_idle_timeout_seconds="$2"
                shift 2
                ;;
            -d|--debug-console)
                [[ $# -ge 2 ]] || fail "Missing value for $1."
                debug_console="$(normalize_boolean "$2")"
                shift 2
                ;;
            -g|--gui-applications)
                [[ $# -ge 2 ]] || fail "Missing value for $1."
                gui_applications="$(normalize_boolean "$2")"
                shift 2
                ;;
            -n|--nested-virtualization)
                [[ $# -ge 2 ]] || fail "Missing value for $1."
                nested_virtualization="$(normalize_boolean "$2")"
                shift 2
                ;;
            --auto-memory-reclaim)
                [[ $# -ge 2 ]] || fail "Missing value for $1."
                auto_memory_reclaim="$(normalize_auto_memory_reclaim "$2")"
                shift 2
                ;;
            --networking-mode)
                [[ $# -ge 2 ]] || fail "Missing value for $1."
                networking_mode="$(normalize_networking_mode "$2")"
                shift 2
                ;;
            --dns-tunneling)
                [[ $# -ge 2 ]] || fail "Missing value for $1."
                dns_tunneling="$(normalize_boolean "$2")"
                shift 2
                ;;
            --dns-proxy)
                [[ $# -ge 2 ]] || fail "Missing value for $1."
                dns_proxy="$(normalize_boolean "$2")"
                shift 2
                ;;
            --firewall)
                [[ $# -ge 2 ]] || fail "Missing value for $1."
                firewall="$(normalize_boolean "$2")"
                shift 2
                ;;
            --sparse-vhd)
                [[ $# -ge 2 ]] || fail "Missing value for $1."
                sparse_vhd="$(normalize_boolean "$2")"
                shift 2
                ;;
            --auto-proxy)
                [[ $# -ge 2 ]] || fail "Missing value for $1."
                auto_proxy="$(normalize_boolean "$2")"
                shift 2
                ;;
            *)
                fail "Unknown option: $1"
                ;;
        esac
    done
}

populate_detected_defaults() {
    if [[ -z "$memory_value" || -z "$swap_size" || -z "$num_processors" ]]; then
        detect_windows_specs
    fi

    if [[ -z "$memory_value" ]]; then
        memory_value="$(recommend_memory_size)"
    fi

    if [[ -z "$swap_size" ]]; then
        swap_size="$(recommend_swap_size)"
    fi

    if [[ -z "$num_processors" ]]; then
        num_processors="$logical_processors"
    fi
}

write_config() {
    local vm_idle_timeout_ms=$(( vm_idle_timeout_seconds * 1000 ))
    local kernel_line="# kernel=C:\\\\Users\\\\<your-user>\\\\WSL2\\\\vmlinux"
    local swapfile_line="# swapfile=C:\\\\Users\\\\<your-user>\\\\AppData\\\\Local\\\\Temp\\\\swap.vhdx"
    local detected_memory_comment=""

    if [[ -n "$kernel_path" ]]; then
        kernel_line="kernel=${kernel_path}"
    fi

    if [[ -n "$swapfile_path" ]]; then
        swapfile_line="swapfile=${swapfile_path}"
    fi

    if [[ -n "$total_memory_gb" ]]; then
        detected_memory_comment="# Detected Windows memory: ${total_memory_gb}GB"
    fi

    cat >"$output_path" <<EOF
[wsl2]
# Specify a custom Linux kernel to use with your installed distros.
${kernel_line}
# Limit the VM memory usage.
${detected_memory_comment}
memory=${memory_value}
# Set the VM virtual processor count.
processors=${num_processors}
# Set swap size. The WSL default is 25% of host RAM.
swap=${swap_size}
# Optional custom swapfile path.
${swapfile_line}
# GUI support for Linux applications (WSLg).
guiApplications=${gui_applications}
# Show a debug console with dmesg output when the distro starts.
debugConsole=${debug_console}
# Enable nested virtualization.
nestedVirtualization=${nested_virtualization}
# Milliseconds before an idle VM is shut down.
vmIdleTimeout=${vm_idle_timeout_ms}
# Network mode. Common values are nat and mirrored.
networkingMode=${networking_mode}
# Configure DNS tunneling through Windows.
dnsTunneling=${dns_tunneling}
# Configure DNS proxy behavior when using NAT.
dnsProxy=${dns_proxy}
# Allow Windows Firewall and Hyper-V rules to filter WSL traffic.
firewall=${firewall}
# Import Windows proxy settings into WSL.
autoProxy=${auto_proxy}

[experimental]
# Automatic reclaim policy for cached memory.
autoMemoryReclaim=${auto_memory_reclaim}
# Create newly generated VHD files as sparse files.
sparseVhd=${sparse_vhd}
EOF
}

print_summary() {
    printf '\nGenerated %s:\n\n' "$output_path"
    cat "$output_path"
    printf '\nApply changes by running "wsl --shutdown" from Windows.\n'
}

main() {
    parse_args "$@"
    populate_detected_defaults
    write_config
    print_summary
}

main "$@"

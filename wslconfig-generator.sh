#!/usr/bin/env bash
#
# Generate a Windows .wslconfig file from detected host hardware or explicit
# overrides. Keys and sections follow
# https://learn.microsoft.com/windows/wsl/wsl-config

set -Eeuo pipefail
shopt -s inherit_errexit
IFS=$'\n\t'

readonly SCRIPT_NAME="${0##*/}"
readonly DEFAULT_OUTPUT_PATH=".wslconfig"

output_path="$DEFAULT_OUTPUT_PATH"
kernel_path=""
kernel_modules_path=""
memory_value=""
num_processors=""
swap_size=""
swapfile_path=""
gui_applications="true"
debug_console="false"
nested_virtualization="true"
vm_idle_timeout_seconds="60"
auto_memory_reclaim="dropCache"
networking_mode="nat"
dns_tunneling="true"
dns_proxy="true"
firewall="true"
sparse_vhd="false"
auto_proxy="true"
total_memory_gb=""
logical_processors=""
pwsh_path=""
temp_file=""

show_help() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Generate a Windows .wslconfig file using detected host hardware values or
explicit overrides. Copy the result to %UserProfile%\\.wslconfig.

Options:
  -h, --help                            Show this help text.
  -e, --examples                        Print example values and exit.
  -o, --output <path>                   Output file path. Default: ${DEFAULT_OUTPUT_PATH}
                                        An existing file is kept as <path>.bak.
  -k, --kernel <path>                   Windows path, or /mnt/<drive> path, to the kernel image.
  -K, --kernel-modules <path>           Windows path, or /mnt/<drive> path, to the modules VHDX.
  -f, --swapfile <path>                 Windows path, or /mnt/<drive> path, to the swap VHDX.
  -m, --memory <size>                   Memory limit. Accepts 24, 24GB or 24576MB.
  -s, --swap <size>                     Swap size. Accepts 8, 8GB, 8192MB or 0 to disable.
  -p, --processors <count>              Processor count.
  -t, --vm-idle-timeout <seconds>       Idle timeout in seconds. Default: 60.
  -d, --debug-console <true|false>      Enable debug console.
  -g, --gui-applications <true|false>   Enable WSLg GUI support.
  -n, --nested-virtualization <true|false>
                                        Enable nested virtualization.
      --auto-memory-reclaim <mode>      disabled, gradual or dropCache. Default: dropCache.
      --networking-mode <mode>          nat, mirrored, none, consomme or virtioproxy
                                        (the older name for consomme). Default: nat.
      --dns-tunneling <true|false>      Enable DNS tunneling.
      --dns-proxy <true|false>          Configure DNS proxy when using NAT.
      --firewall <true|false>           Let Windows Firewall filter WSL traffic.
      --sparse-vhd <true|false>         Create new VHDs as sparse files.
      --auto-proxy <true|false>         Import Windows proxy settings into WSL.

Examples:
  ${SCRIPT_NAME} --kernel 'C:\\Users\\me\\WSL2\\bzImage' --memory 24 --processors 8
  ${SCRIPT_NAME} --kernel /mnt/c/Users/me/WSL2/bzImage --kernel-modules /mnt/c/Users/me/WSL2/modules.vhdx
EOF
}

show_examples() {
    cat <<'EOF'
Example values, as written to .wslconfig:
  kernel=C:\\Users\\me\\WSL2\\bzImage
  kernelModules=C:\\Users\\me\\WSL2\\modules.vhdx
  memory=24GB
  processors=8
  swap=8GB
  swapFile=C:\\Users\\me\\AppData\\Local\\Temp\\swap.vhdx
  guiApplications=true
  debugConsole=false
  nestedVirtualization=true
  vmIdleTimeout=60000
  networkingMode=nat
  dnsTunneling=true
  dnsProxy=true
  firewall=true
  autoProxy=true
  autoMemoryReclaim=dropCache
  sparseVhd=false
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
        true | false)
            printf '%s\n' "$value"
            ;;
        *)
            fail "Invalid boolean value: $1"
            ;;
    esac
}

# Prints the size with a unit (a bare number means GB), or 0 for any zero size.
normalize_size() {
    [[ "${1^^}" =~ ^0*([0-9]+)(GB|MB)?$ ]] ||
        fail "Invalid size value: $1. Use values like 24, 24GB, or 24576MB."

    if [[ "${BASH_REMATCH[1]}" == "0" ]]; then
        printf '0\n'
    else
        printf '%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]:-GB}"
    fi
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
    ((10#$value > 0)) || fail "${label} must be greater than zero."
}

# Maps the default WSL drive mount /mnt/<drive>/dir to <DRIVE>:/dir; prints
# nothing for any other path.
drive_mount_to_windows() {
    if [[ "$1" =~ ^/mnt/([A-Za-z])(/.*)?$ ]]; then
        printf '%s:%s\n' "${BASH_REMATCH[1]^^}" "${BASH_REMATCH[2]:-/}"
    fi
}

# Converts a Windows path (C:\dir, C:/dir) or a WSL drive mount path
# (/mnt/c/dir) to the escaped form .wslconfig requires (C:\\dir). WSL reads
# these files from Windows before the VM starts, so only drive paths work.
# wslpath handles custom automount roots; the /mnt mapping covers hosts
# without wslpath and files that do not exist yet.
normalize_windows_path() {
    local raw_path=$1
    local windows_path=$raw_path

    if [[ "$raw_path" == /* ]]; then
        windows_path=""
        if command_exists wslpath; then
            windows_path="$(wslpath -w "$raw_path" 2>/dev/null || true)"
        fi
        if [[ -z "$windows_path" ]]; then
            windows_path="$(drive_mount_to_windows "$raw_path")"
        fi
    fi

    windows_path="${windows_path//\//\\}"
    [[ "$windows_path" =~ ^[A-Za-z]:\\ ]] ||
        fail "Path must be on a Windows drive (C:\\... or /mnt/c/...): ${raw_path}"

    printf '%s\n' "$windows_path" | sed -E 's#\\+#\\\\#g'
}

find_powershell() {
    local candidate

    if command_exists powershell.exe; then
        pwsh_path="$(command -v powershell.exe)"
        return
    fi

    for candidate in \
        "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" \
        "/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"; do
        if [[ -x "$candidate" ]]; then
            pwsh_path="$candidate"
            return
        fi
    done

    fail "Unable to locate powershell.exe. Run from WSL on Windows, or pass --memory, --swap and --processors."
}

run_powershell() {
    "$pwsh_path" -NoLogo -NoProfile -NonInteractive -Command "$1" 2>/dev/null | tr -d '\r'
}

detect_windows_specs() {
    local total_memory_bytes

    find_powershell

    total_memory_bytes="$(run_powershell '(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory')"
    [[ "$total_memory_bytes" =~ ^[0-9]+$ ]] || fail "Failed to detect Windows physical memory."
    total_memory_gb=$((total_memory_bytes / 1024 / 1024 / 1024))
    ((total_memory_gb > 0)) || fail "Detected Windows physical memory is invalid."

    logical_processors="$(run_powershell '(Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors')"
    if [[ ! "$logical_processors" =~ ^[0-9]+$ ]] || ((logical_processors == 0)); then
        fail "Failed to detect the number of Windows logical processors."
    fi
}

# Half of host memory, matching the WSL default.
recommend_memory_size() {
    local recommended=$((total_memory_gb / 2))

    if ((recommended < 2)); then
        recommended=2
    fi

    printf '%sGB\n' "$recommended"
}

# A quarter of host memory rounded up, matching the WSL default.
recommend_swap_size() {
    local recommended=$(((total_memory_gb + 3) / 4))

    if ((recommended < 1)); then
        recommended=1
    fi

    printf '%sGB\n' "$recommended"
}

normalize_networking_mode() {
    local mode=${1,,}

    case "$mode" in
        nat | mirrored | none | consomme | virtioproxy)
            printf '%s\n' "$mode"
            ;;
        bridged)
            fail "Networking mode 'bridged' is deprecated since WSL 2.4.5 and needs a vmSwitch. Use mirrored or nat."
            ;;
        *)
            fail "Invalid networking mode: $1"
            ;;
    esac
}

normalize_auto_memory_reclaim() {
    case "${1,,}" in
        disabled | gradual)
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

require_value() {
    (($2 >= 2)) || fail "Missing value for $1."
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            -h | --help)
                show_help
                exit 0
                ;;
            -e | --examples)
                show_examples
                exit 0
                ;;
            -o | --output)
                require_value "$1" "$#"
                output_path="$2"
                shift 2
                ;;
            -k | --kernel)
                require_value "$1" "$#"
                kernel_path="$(normalize_windows_path "$2")"
                shift 2
                ;;
            -K | --kernel-modules)
                require_value "$1" "$#"
                kernel_modules_path="$(normalize_windows_path "$2")"
                shift 2
                ;;
            -f | --swapfile)
                require_value "$1" "$#"
                swapfile_path="$(normalize_windows_path "$2")"
                shift 2
                ;;
            -m | --memory)
                require_value "$1" "$#"
                memory_value="$(normalize_size "$2")"
                [[ "$memory_value" != "0" ]] || fail "Memory must be greater than zero."
                shift 2
                ;;
            -s | --swap)
                require_value "$1" "$#"
                swap_size="$(normalize_size "$2")"
                shift 2
                ;;
            -p | --processors)
                require_value "$1" "$#"
                validate_positive_integer "$2" "Processor count"
                num_processors="$((10#$2))"
                shift 2
                ;;
            -t | --vm-idle-timeout)
                require_value "$1" "$#"
                validate_non_negative_integer "$2" "VM idle timeout"
                vm_idle_timeout_seconds="$((10#$2))"
                shift 2
                ;;
            -d | --debug-console)
                require_value "$1" "$#"
                debug_console="$(normalize_boolean "$2")"
                shift 2
                ;;
            -g | --gui-applications)
                require_value "$1" "$#"
                gui_applications="$(normalize_boolean "$2")"
                shift 2
                ;;
            -n | --nested-virtualization)
                require_value "$1" "$#"
                nested_virtualization="$(normalize_boolean "$2")"
                shift 2
                ;;
            --auto-memory-reclaim)
                require_value "$1" "$#"
                auto_memory_reclaim="$(normalize_auto_memory_reclaim "$2")"
                shift 2
                ;;
            --networking-mode)
                require_value "$1" "$#"
                networking_mode="$(normalize_networking_mode "$2")"
                shift 2
                ;;
            --dns-tunneling)
                require_value "$1" "$#"
                dns_tunneling="$(normalize_boolean "$2")"
                shift 2
                ;;
            --dns-proxy)
                require_value "$1" "$#"
                dns_proxy="$(normalize_boolean "$2")"
                shift 2
                ;;
            --firewall)
                require_value "$1" "$#"
                firewall="$(normalize_boolean "$2")"
                shift 2
                ;;
            --sparse-vhd)
                require_value "$1" "$#"
                sparse_vhd="$(normalize_boolean "$2")"
                shift 2
                ;;
            --auto-proxy)
                require_value "$1" "$#"
                auto_proxy="$(normalize_boolean "$2")"
                shift 2
                ;;
            *)
                fail "Unknown option: $1. Run '${SCRIPT_NAME} --help'."
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

# Prints "key=value", or a commented placeholder when value is empty.
setting_or_placeholder() {
    local key=$1
    local value=$2
    local placeholder=$3

    if [[ -n "$value" ]]; then
        printf '%s=%s\n' "$key" "$value"
    else
        printf '# %s=%s\n' "$key" "$placeholder"
    fi
}

render_config() {
    printf '[wsl2]\n'
    printf '# Custom Linux kernel image (bzImage) on the Windows filesystem.\n'
    setting_or_placeholder kernel "$kernel_path" 'C:\\Users\\<your-user>\\WSL2\\bzImage'
    printf '# Modules VHDX built for that kernel.\n'
    setting_or_placeholder kernelModules "$kernel_modules_path" 'C:\\Users\\<your-user>\\WSL2\\modules.vhdx'
    if [[ -n "$total_memory_gb" ]]; then
        printf '# VM memory limit. Detected Windows memory: %sGB.\n' "$total_memory_gb"
    else
        printf '# VM memory limit.\n'
    fi
    printf 'memory=%s\n' "$memory_value"
    printf '# Virtual processor count.\n'
    printf 'processors=%s\n' "$num_processors"
    printf '# Swap size; 0 disables swap. The WSL default is 25%% of host memory.\n'
    printf 'swap=%s\n' "$swap_size"
    printf '# Swap VHDX location. The WSL default is %%Temp%%\\swap.vhdx.\n'
    setting_or_placeholder swapFile "$swapfile_path" 'C:\\Users\\<your-user>\\AppData\\Local\\Temp\\swap.vhdx'
    printf '# GUI support for Linux applications (WSLg).\n'
    printf 'guiApplications=%s\n' "$gui_applications"
    printf '# Console window with dmesg output at distro start (Windows 11).\n'
    printf 'debugConsole=%s\n' "$debug_console"
    printf '# Nested virtualization inside WSL 2 (Windows 11).\n'
    printf 'nestedVirtualization=%s\n' "$nested_virtualization"
    printf '# Milliseconds before an idle VM shuts down (Windows 11).\n'
    printf 'vmIdleTimeout=%s\n' "$((vm_idle_timeout_seconds * 1000))"
    printf '# Network mode: nat, mirrored, none or consomme.\n'
    printf 'networkingMode=%s\n' "$networking_mode"
    printf '# Proxy DNS requests through Windows.\n'
    printf 'dnsTunneling=%s\n' "$dns_tunneling"
    printf '# Point Linux DNS at the NAT on the host (NAT mode only).\n'
    printf 'dnsProxy=%s\n' "$dns_proxy"
    printf '# Let Windows Firewall and Hyper-V rules filter WSL traffic.\n'
    printf 'firewall=%s\n' "$firewall"
    printf '# Use the Windows HTTP proxy settings.\n'
    printf 'autoProxy=%s\n' "$auto_proxy"
    printf '\n[experimental]\n'
    printf '# Reclaim cached memory: disabled, gradual or dropCache.\n'
    printf 'autoMemoryReclaim=%s\n' "$auto_memory_reclaim"
    printf '# Create new VHDs as sparse files.\n'
    printf 'sparseVhd=%s\n' "$sparse_vhd"
}

remove_temp_file() {
    if [[ -n "$temp_file" ]]; then
        rm -f -- "$temp_file"
    fi
}

# Renders fully before touching the filesystem, then replaces the output with
# a rename so a failure never leaves a truncated .wslconfig behind.
write_config() {
    local output_dir content

    output_dir="$(dirname -- "$output_path")"
    [[ -d "$output_dir" ]] || fail "Output directory does not exist: ${output_dir}"
    [[ ! -d "$output_path" ]] || fail "Output path is a directory: ${output_path}"

    content="$(render_config)"
    temp_file="$(mktemp "${output_dir}/.wslconfig.XXXXXX")"
    trap remove_temp_file EXIT
    printf '%s\n' "$content" >"$temp_file"
    chmod 0644 -- "$temp_file"

    if [[ -e "$output_path" ]]; then
        cp -p -- "$output_path" "${output_path}.bak"
        printf 'Previous %s saved as %s.bak\n' "$output_path" "$output_path"
    fi
    mv -f -- "$temp_file" "$output_path"
    temp_file=""
}

print_summary() {
    printf '\nGenerated %s:\n\n' "$output_path"
    cat -- "$output_path"
    printf '\nCopy it to %%UserProfile%%\\.wslconfig, then run "wsl --shutdown" from Windows.\n'
}

main() {
    parse_args "$@"
    populate_detected_defaults
    write_config
    print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

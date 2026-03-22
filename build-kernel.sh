#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="${0##*/}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SCRIPT_VERSION="4.0.0"
readonly KERNEL_REPO_URL="https://github.com/microsoft/WSL2-Linux-Kernel.git"
readonly DEFAULT_KERNEL_SERIES="6"

if [[ -t 1 ]]; then
    readonly RED=$'\033[0;31m'
    readonly GREEN=$'\033[0;32m'
    readonly YELLOW=$'\033[0;33m'
    readonly RESET=$'\033[0m'
else
    readonly RED=""
    readonly GREEN=""
    readonly YELLOW=""
    readonly RESET=""
fi

readonly TARGET_UID="${SUDO_UID:-$(id -u)}"
readonly TARGET_GID="${SUDO_GID:-$(id -g)}"

output_directory="$PWD"
kernel_version=""
kernel_series=""
generate_wslconfig="ask"
keep_build_dir="false"
list_versions_only="false"
workspace=""
archive_path=""
source_dir=""
build_log=""
selected_version=""
apt_updated="false"

show_help() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Build the Microsoft WSL2 kernel from source and copy the resulting vmlinux file
to the selected output directory.

Options:
  -h, --help                        Show this help message.
  -V, --script-version              Show the script version.
  -v, --version <version>           Build a specific WSL kernel tag version.
      --series <5|6>                Build the latest version from a major series.
  -o, --output-directory <dir>      Directory to receive the built vmlinux file.
      --list-versions               Print available upstream kernel versions.
      --generate-wslconfig          Run the local .wslconfig generator after build.
      --skip-wslconfig              Skip the .wslconfig generator prompt.
      --keep-build-dir              Preserve the temporary build directory.

Examples:
  sudo bash ${SCRIPT_NAME}
  sudo bash ${SCRIPT_NAME} --series 6 --output-directory "\$HOME/WSL2"
  sudo bash ${SCRIPT_NAME} --version 6.6.87.2 --skip-wslconfig
EOF
}

log() {
    printf '%s[INFO]%s %s\n' "$GREEN" "$RESET" "$*"
}

warn() {
    printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*" >&2
}

fail() {
    printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$*" >&2
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

cleanup() {
    local status=$?

    if [[ -z "$workspace" || ! -d "$workspace" ]]; then
        return "$status"
    fi

    if (( status != 0 )); then
        warn "Build workspace preserved for inspection: $workspace"
        return "$status"
    fi

    if [[ "$keep_build_dir" == "true" ]]; then
        log "Build workspace retained: $workspace"
        return 0
    fi

    rm -rf -- "$workspace"
    return 0
}

trap cleanup EXIT

ensure_root() {
    [[ "$EUID" -eq 0 ]] || fail "Run this script with root privileges."
}

ensure_directory() {
    mkdir -p -- "$1"
}

ensure_output_directory() {
    ensure_directory "$output_directory"
}

own_file_for_user() {
    local target=$1

    if command_exists chown; then
        chown "$TARGET_UID:$TARGET_GID" "$target" 2>/dev/null || true
    fi
}

apt_install_missing_packages() {
    local -a required_packages=(
        bc
        bison
        build-essential
        ca-certificates
        ccache
        curl
        dwarves
        flex
        git
        libcap-dev
        libelf-dev
        libncurses-dev
        libssl-dev
        python3
        rsync
        wget
        xz-utils
    )
    local -a missing_packages=()
    local package

    for package in "${required_packages[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "ok installed"; then
            missing_packages+=("$package")
        fi
    done

    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        log "Build dependencies are already installed."
        return
    fi

    log "Installing missing packages: ${missing_packages[*]}"

    if [[ "$apt_updated" != "true" ]]; then
        apt-get update
        apt_updated="true"
    fi

    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing_packages[@]}"
}

fetch_available_versions() {
    command_exists git || fail "git is required to resolve available kernel versions."

    git ls-remote --tags --refs "$KERNEL_REPO_URL" 'refs/tags/linux-msft-wsl-*' |
        awk '{print $2}' |
        sed 's#refs/tags/linux-msft-wsl-##' |
        grep -E '^[0-9]+(\.[0-9]+)*$' |
        sort -Vru
}

list_available_versions() {
    log "Available upstream kernel versions:"
    fetch_available_versions
}

resolve_latest_version_for_series() {
    local series=$1

    fetch_available_versions | awk -F. -v target="$series" '$1 == target { print; exit }'
}

prompt_for_version_selection() {
    local choice

    while true; do
        cat <<'EOF'

Choose the WSL2 kernel version to build:
1. Latest Linux series 6 kernel
2. Latest Linux series 5 kernel
3. Specific version
4. List available versions
5. Exit
EOF
        read -r -p "Enter your choice (1-5): " choice

        case "$choice" in
            1)
                kernel_series="6"
                return
                ;;
            2)
                kernel_series="5"
                return
                ;;
            3)
                read -r -p "Enter the full version (example: 6.6.87.2): " kernel_version
                [[ -n "$kernel_version" ]] || fail "A version value is required."
                return
                ;;
            4)
                list_available_versions
                ;;
            5)
                exit 0
                ;;
            *)
                warn "Invalid choice. Enter a number between 1 and 5."
                ;;
        esac
    done
}

resolve_selected_version() {
    if [[ -n "$kernel_version" ]]; then
        selected_version="$kernel_version"
        return
    fi

    if [[ -z "$kernel_series" ]]; then
        if [[ -t 0 ]]; then
            prompt_for_version_selection
        else
            kernel_series="$DEFAULT_KERNEL_SERIES"
            log "No version specified; defaulting to latest series ${kernel_series} kernel."
        fi
    fi

    selected_version="$(resolve_latest_version_for_series "$kernel_series")"
    [[ -n "$selected_version" ]] || fail "Failed to resolve the latest series ${kernel_series} kernel version."
}

prepare_workspace() {
    workspace="$(mktemp -d "${TMPDIR:-/tmp}/wsl2-kernel-build.XXXXXX")"
    archive_path="${workspace}/kernel.tar.gz"
    source_dir="${workspace}/source"
    build_log="${workspace}/build.log"

    mkdir -p -- "$source_dir"
}

download_source_archive() {
    local version=$1
    local archive_url="https://github.com/microsoft/WSL2-Linux-Kernel/archive/refs/tags/linux-msft-wsl-${version}.tar.gz"

    log "Downloading kernel source for ${version}..."
    curl --fail --location --retry 3 --retry-delay 2 --silent --show-error \
        --output "$archive_path" "$archive_url"
}

extract_source_archive() {
    log "Extracting source archive..."
    tar -xzf "$archive_path" -C "$source_dir" --strip-components=1
    [[ -f "${source_dir}/Microsoft/config-wsl" ]] || fail "The upstream source archive is missing Microsoft/config-wsl."
}

run_logged() {
    "$@" 2>&1 | tee -a "$build_log"
}

build_kernel() {
    log "Preparing kernel configuration..."
    cp -- "${source_dir}/Microsoft/config-wsl" "${source_dir}/.config"

    (
        cd -- "$source_dir"
        run_logged make olddefconfig
        run_logged make -j"$(nproc --all)"
        run_logged make modules_install headers_install
    )
}

copy_vmlinux() {
    local source_vmlinux="${source_dir}/vmlinux"
    local destination="${output_directory}/vmlinux"

    [[ -f "$source_vmlinux" ]] || fail "Kernel build completed without producing vmlinux."

    install -m 0644 "$source_vmlinux" "$destination"
    own_file_for_user "$destination"

    log "Kernel build complete. vmlinux written to ${destination}"
}

prompt_wslconfig_generation() {
    local choice

    if [[ "$generate_wslconfig" == "false" ]]; then
        return
    fi

    if [[ "$generate_wslconfig" == "true" ]]; then
        run_wslconfig_generator
        return
    fi

    [[ -t 0 ]] || return

    while true; do
        read -r -p "Run the local .wslconfig generator now? (y/n): " choice
        case "$choice" in
            [Yy]*)
                run_wslconfig_generator
                return
                ;;
            [Nn]*)
                return
                ;;
            *)
                warn "Enter y or n."
                ;;
        esac
    done
}

run_wslconfig_generator() {
    local generator_path="${SCRIPT_DIR}/wslconfig-generator.sh"

    [[ -x "$generator_path" || -f "$generator_path" ]] || fail "Unable to find ${generator_path}."

    log "Launching the local .wslconfig generator..."
    bash "$generator_path"

    if [[ -f "${PWD}/.wslconfig" ]]; then
        own_file_for_user "${PWD}/.wslconfig"
        log ".wslconfig written to ${PWD}/.wslconfig"
    fi
}

print_next_steps() {
    cat <<EOF

Next steps:
  1. Copy ${output_directory}/vmlinux somewhere stable on Windows, for example:
     C:\\Users\\<your-user>\\WSL2\\vmlinux
  2. Point your Windows .wslconfig file at that kernel path.
  3. Run 'wsl --shutdown' from Windows to apply the new kernel.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -V|--script-version)
                printf '%s\n' "$SCRIPT_VERSION"
                exit 0
                ;;
            -v|--version)
                [[ $# -ge 2 ]] || fail "Missing value for $1."
                kernel_version="$2"
                shift 2
                ;;
            --series)
                [[ $# -ge 2 ]] || fail "Missing value for $1."
                [[ "$2" =~ ^[56]$ ]] || fail "Kernel series must be 5 or 6."
                kernel_series="$2"
                shift 2
                ;;
            -o|--output-directory)
                [[ $# -ge 2 ]] || fail "Missing value for $1."
                output_directory="$2"
                shift 2
                ;;
            --list-versions)
                list_versions_only="true"
                shift
                ;;
            --generate-wslconfig)
                generate_wslconfig="true"
                shift
                ;;
            --skip-wslconfig)
                generate_wslconfig="false"
                shift
                ;;
            --keep-build-dir)
                keep_build_dir="true"
                shift
                ;;
            *)
                fail "Unknown option: $1"
                ;;
        esac
    done

    if [[ -n "$kernel_version" && -n "$kernel_series" ]]; then
        warn "Both --version and --series were supplied; --version takes precedence."
    fi
}

main() {
    parse_args "$@"

    if [[ "$list_versions_only" == "true" ]]; then
        list_available_versions
        exit 0
    fi

    ensure_root
    ensure_output_directory
    apt_install_missing_packages
    resolve_selected_version
    prepare_workspace
    download_source_archive "$selected_version"
    extract_source_archive
    build_kernel
    copy_vmlinux
    print_next_steps
    prompt_wslconfig_generation
}

main "$@"

#!/usr/bin/env bash
#
# Build the Microsoft WSL2 kernel from source and produce the two files that
# .wslconfig consumes: the kernel image (kernel=) and the modules VHDX
# (kernelModules=). Follows the build steps in the upstream README.

set -Eeuo pipefail
shopt -s inherit_errexit
IFS=$'\n\t'

readonly SCRIPT_NAME="${0##*/}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SCRIPT_VERSION="5.0.0"
readonly KERNEL_REPO_URL="https://github.com/microsoft/WSL2-Linux-Kernel"
readonly TAG_PREFIX="linux-msft-wsl-"
readonly BUNDLED_FRAGMENT="${SCRIPT_DIR}/wsl-can.config"
readonly DEFAULT_BUILD_PARENT="/var/tmp"
# A 6.18.54.1 build tree measured 11 GB; the margin covers VHDX staging and
# growth in later releases.
readonly MIN_FREE_GB=20
readonly -a REQUIRED_PACKAGES=(
    bc
    bison
    build-essential
    ca-certificates
    cpio
    curl
    dwarves
    e2fsprogs
    fakeroot
    flex
    git
    kmod
    libelf-dev
    libssl-dev
    openssl
    pkg-config
    python3
    qemu-utils
    rsync
)

if [[ -z "${NO_COLOR-}" && -t 2 ]]; then
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

output_directory="$PWD"
build_parent="$DEFAULT_BUILD_PARENT"
kernel_version=""
kernel_series=""
series_requested="false"
jobs=""
config_path=""
use_bundled_fragment="true"
extra_fragments=()
generate_wslconfig="ask"
keep_build_dir="false"
list_versions_only="false"
available_versions=""
selected_version=""
kernel_release=""
workspace=""
source_dir=""
build_log=""
kernel_dest=""
modules_dest=""

show_help() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Build the Microsoft WSL2 kernel from source. Produces bzImage-<version>,
modules-<version>.vhdx and config-<version> in the output directory.
Run as a regular user; sudo is used only to install missing packages.

Options:
  -h, --help                    Show this help message.
  -V, --script-version          Show the script version.
  -v, --version <version>       Build an exact upstream tag, e.g. 6.18.54.1.
      --series <series>         Build the newest tag in a series, e.g. 6.18 or 6.6.
                                Default: the newest tag overall.
  -o, --output-directory <dir>  Directory that receives the build artifacts.
                                Default: the current directory.
  -c, --config <path>           Base .config to use instead of the upstream
                                Microsoft/config-wsl of the selected version.
  -f, --fragment <path>         Extra config fragment to merge (repeatable).
      --stock-config            Do not merge the bundled wsl-can.config fragment.
  -j, --jobs <count>            Parallel make jobs. Default: nproc.
  -b, --build-dir <dir>         Parent directory for the temporary build tree.
                                Must be a Linux filesystem with ${MIN_FREE_GB} GB free.
                                Default: ${DEFAULT_BUILD_PARENT}
      --list-versions           Print available upstream versions and exit.
      --generate-wslconfig      Run wslconfig-generator.sh after the build.
      --skip-wslconfig          Do not offer to run wslconfig-generator.sh.
      --keep-build-dir          Keep the temporary build tree after success.

Examples:
  bash ${SCRIPT_NAME}
  bash ${SCRIPT_NAME} --series 6.6 --output-directory /mnt/c/Users/me/WSL2
  bash ${SCRIPT_NAME} --version 6.18.54.1 --skip-wslconfig
  bash ${SCRIPT_NAME} --stock-config --fragment ./my-options.config
EOF
}

log() {
    printf '%s[INFO]%s %s\n' "$GREEN" "$RESET" "$*" >&2
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

join_by_space() {
    local IFS=' '
    printf '%s' "$*"
}

absolute_path() {
    local path=$1
    local directory
    directory="$(cd -- "$(dirname -- "$path")" && pwd)"
    printf '%s/%s\n' "$directory" "$(basename -- "$path")"
}

cleanup() {
    local status=$?

    if [[ -z "$workspace" || ! -d "$workspace" ]]; then
        return "$status"
    fi

    if ((status != 0)); then
        warn "Build tree preserved for inspection: ${workspace}"
        if [[ -n "$build_log" && -f "$build_log" ]]; then
            warn "Build log: ${build_log}"
        fi
        return "$status"
    fi

    if [[ "$keep_build_dir" == "true" ]]; then
        log "Build tree retained: ${workspace}"
        return 0
    fi

    rm -rf -- "$workspace"
    return 0
}

run_as_root() {
    if ((EUID == 0)); then
        "$@"
        return
    fi

    command_exists sudo || fail "Root access is needed to run: $(join_by_space "$@")"
    sudo -- "$@"
}

own_file_for_user() {
    if ((EUID == 0)) && [[ -n "${SUDO_UID-}" && -n "${SUDO_GID-}" ]]; then
        chown -- "${SUDO_UID}:${SUDO_GID}" "$1" 2>/dev/null || true
    fi
}

check_host() {
    local machine
    machine="$(uname -m)"
    [[ "$machine" == "x86_64" ]] || fail "Unsupported architecture '${machine}'. Microsoft documents x86_64 builds only."
    command_exists apt-get || fail "apt-get not found. This script supports Debian and Ubuntu distributions."

    if ((EUID == 0)); then
        warn "Running as root. Kernel builds should run as a regular user; the script calls sudo only for apt-get."
    fi
}

package_installed() {
    local status
    status="$(dpkg-query --show --showformat='${db:Status-Abbrev}' "$1" 2>/dev/null || true)"
    [[ "$status" == ii* ]]
}

install_missing_packages() {
    local -a missing_packages=()
    local package

    for package in "${REQUIRED_PACKAGES[@]}"; do
        package_installed "$package" || missing_packages+=("$package")
    done

    if ((${#missing_packages[@]} == 0)); then
        log "Build dependencies are already installed."
        return
    fi

    log "Installing missing packages: $(join_by_space "${missing_packages[@]}")"
    run_as_root apt-get update
    run_as_root env DEBIAN_FRONTEND=noninteractive \
        apt-get install --yes --no-install-recommends "${missing_packages[@]}"
}

fetch_available_versions() {
    git ls-remote --tags --refs "${KERNEL_REPO_URL}.git" "refs/tags/${TAG_PREFIX}*" |
        awk -v prefix="refs/tags/${TAG_PREFIX}" 'index($2, prefix) == 1 { print substr($2, length(prefix) + 1) }' |
        grep -E '^[0-9]+(\.[0-9]+)+$' |
        sort -Vr
}

load_available_versions() {
    if [[ -n "$available_versions" ]]; then
        return
    fi

    command_exists git || fail "git is required to list upstream kernel versions."
    available_versions="$(fetch_available_versions)" ||
        fail "Unable to list ${TAG_PREFIX}* tags from ${KERNEL_REPO_URL}."
    [[ -n "$available_versions" ]] || fail "No ${TAG_PREFIX}* tags found at ${KERNEL_REPO_URL}."
}

version_is_available() {
    grep -qxF -- "$1" <<<"$available_versions"
}

# Prints the newest available version equal to the series or inside it.
# An empty series matches every version.
latest_version_in_series() {
    local series=$1
    local version

    while IFS= read -r version; do
        if [[ -z "$series" || "$version" == "$series" || "$version" == "$series".* ]]; then
            printf '%s\n' "$version"
            return 0
        fi
    done <<<"$available_versions"

    return 1
}

prompt_for_version_selection() {
    local choice

    while true; do
        cat >&2 <<'EOF'

Choose the WSL2 kernel version to build:
1. Newest release
2. Newest release in a series (for example 6.6)
3. Exact version
4. List available versions
5. Exit
EOF
        read -r -p "Enter your choice (1-5): " choice

        case "$choice" in
            1)
                return
                ;;
            2)
                read -r -p "Enter the series (for example 6.18 or 6.6): " kernel_series
                validate_series "$kernel_series"
                series_requested="true"
                return
                ;;
            3)
                read -r -p "Enter the version (for example 6.18.54.1): " kernel_version
                validate_version_format "$kernel_version"
                return
                ;;
            4)
                load_available_versions
                printf '%s\n' "$available_versions" >&2
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
    load_available_versions

    if [[ -n "$kernel_version" ]]; then
        version_is_available "$kernel_version" ||
            fail "Version ${kernel_version} is not an upstream tag. Run '${SCRIPT_NAME} --list-versions'."
        selected_version="$kernel_version"
    else
        selected_version="$(latest_version_in_series "$kernel_series")" ||
            fail "No upstream version matches series ${kernel_series}. Run '${SCRIPT_NAME} --list-versions'."
    fi

    log "Selected WSL2 kernel version ${selected_version}."
}

filesystem_type() {
    findmnt --noheadings --output FSTYPE --target "$1" 2>/dev/null | head -n 1 || true
}

require_supported_filesystem() {
    local fs_type=$1
    local directory=$2

    case "$fs_type" in
        9p | drvfs | virtiofs | cifs | smb3 | fuseblk | ntfs | ntfs3 | vfat | exfat)
            fail "Build directory ${directory} is on a ${fs_type} filesystem. Use a Linux filesystem; the kernel tree has files whose names differ only by case."
            ;;
        tmpfs)
            warn "Build directory ${directory} is on tmpfs, which holds the whole build in RAM."
            ;;
        *) ;;
    esac
}

check_build_location() {
    local fs_type available_kb

    mkdir -p -- "$build_parent"
    build_parent="$(cd -- "$build_parent" && pwd)"

    fs_type="$(filesystem_type "$build_parent")"
    require_supported_filesystem "$fs_type" "$build_parent"

    available_kb="$(df -Pk -- "$build_parent" | awk 'NR == 2 { print $4 }')"
    if [[ ! "$available_kb" =~ ^[0-9]+$ ]]; then
        warn "Could not determine free space in ${build_parent}."
        return
    fi

    ((available_kb >= MIN_FREE_GB * 1024 * 1024)) ||
        fail "Build directory ${build_parent} has $((available_kb / 1024 / 1024)) GB free; ${MIN_FREE_GB} GB is required. Choose another with --build-dir."
}

prepare_output_directory() {
    mkdir -p -- "$output_directory"
    output_directory="$(cd -- "$output_directory" && pwd)"
    [[ -w "$output_directory" ]] || fail "Output directory ${output_directory} is not writable."
}

prepare_workspace() {
    workspace="$(mktemp -d "${build_parent%/}/wsl2-kernel-build.XXXXXX")"
    source_dir="${workspace}/source"
    build_log="${workspace}/build.log"
    mkdir -p -- "$source_dir"
}

run_logged() {
    {
        printf '\n===== %s | %s =====\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(join_by_space "$@")"
        "$@"
    } 2>&1 | tee -a -- "$build_log"
}

download_source() {
    local archive_path="${workspace}/source.tar.gz"
    local archive_url="${KERNEL_REPO_URL}/archive/refs/tags/${TAG_PREFIX}${selected_version}.tar.gz"

    log "Downloading ${archive_url}"
    curl --proto '=https' --tlsv1.2 --fail --location --retry 3 --retry-delay 2 \
        --silent --show-error --output "$archive_path" "$archive_url"

    log "Extracting source archive..."
    tar -xzf "$archive_path" -C "$source_dir" --strip-components=1 --no-same-owner
    rm -f -- "$archive_path"

    [[ -f "${source_dir}/Microsoft/config-wsl" ]] ||
        fail "The source archive does not contain Microsoft/config-wsl."
}

# Fails unless every assignment in the fragments survived into the final config.
# "# CONFIG_X is not set" and CONFIG_X=n are satisfied by an absent symbol.
verify_config_fragments() {
    local final_config=$1
    shift
    local -A final_values=()
    local -a mismatches=()
    local fragment line symbol expected actual

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^(CONFIG_[A-Za-z0-9_]+)=(.*)$ ]]; then
            final_values["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
        fi
    done <"$final_config"

    for fragment in "$@"; do
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ ^(CONFIG_[A-Za-z0-9_]+)=(.*)$ ]]; then
                symbol=${BASH_REMATCH[1]}
                expected=${BASH_REMATCH[2]}
            elif [[ "$line" =~ ^#\ (CONFIG_[A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
                symbol=${BASH_REMATCH[1]}
                expected="n"
            else
                continue
            fi

            actual="${final_values[$symbol]-n}"
            if [[ "$actual" != "$expected" ]]; then
                mismatches+=("${symbol}: requested ${expected}, got ${actual} (${fragment##*/})")
            fi
        done <"$fragment"
    done

    if ((${#mismatches[@]} > 0)); then
        printf '%s[ERROR]%s Config fragment values were not applied:\n' "$RED" "$RESET" >&2
        printf '  %s\n' "${mismatches[@]}" >&2
        fail "Check symbol names and dependencies for kernel ${selected_version}."
    fi
}

configure_kernel() {
    local base_config="${config_path:-${source_dir}/Microsoft/config-wsl}"
    local -a fragments=()
    local fragment

    if [[ "$use_bundled_fragment" == "true" ]]; then
        [[ -f "$BUNDLED_FRAGMENT" ]] || fail "Bundled fragment not found: ${BUNDLED_FRAGMENT}"
        fragments+=("$BUNDLED_FRAGMENT")
    fi
    fragments+=("${extra_fragments[@]}")

    log "Base config: ${base_config}"
    if ((${#fragments[@]} == 0)); then
        cp -- "$base_config" "${source_dir}/.config"
    else
        for fragment in "${fragments[@]}"; do
            log "Merging fragment: ${fragment}"
        done
        # merge_config.sh creates its temporary files in the current directory.
        (
            cd -- "$source_dir"
            run_logged ./scripts/kconfig/merge_config.sh -m -O "$source_dir" "$base_config" "${fragments[@]}"
        )
    fi

    run_logged make -C "$source_dir" olddefconfig
    verify_config_fragments "${source_dir}/.config" "${fragments[@]}"
}

build_kernel() {
    log "Building kernel ${selected_version} with ${jobs} jobs..."
    run_logged make -C "$source_dir" -j"$jobs"

    kernel_release="$(make -s --no-print-directory -C "$source_dir" kernelrelease)"
    [[ -n "$kernel_release" ]] || fail "Unable to determine the kernel release string."

    # Strips debug sections and keeps .BTF, matching the modules Microsoft ships.
    run_logged make -C "$source_dir" -j"$jobs" INSTALL_MOD_STRIP=1 \
        INSTALL_MOD_PATH="${workspace}/modules" modules_install
    run_logged make -C "$source_dir" INSTALL_HDR_PATH="${workspace}/headers" headers_install
}

# Writes the layout WSL mounts, <release>/{modules,linux-headers}, for trees
# without Microsoft/scripts/gen_artifacts_vhdx.sh; WSL deprecates the older
# flat layout. fakeroot makes every file root-owned, as in Microsoft's image,
# because WSL mounts the modules writable through overlayfs.
create_artifacts_vhdx() {
    local modules_root=$1
    local headers_dir=$2
    local release=$3
    local output=$4
    local scratch=$5
    local staging="${scratch}/vhdx-staging"
    local image="${scratch}/modules.img"
    local fakeroot_state="${scratch}/fakeroot.state"
    local staging_bytes file_count

    mkdir -p -- "${staging}/${release}"
    cp -a -- "${modules_root}/lib/modules/${release}" "${staging}/${release}/modules"
    rm -f -- "${staging}/${release}/modules/build" "${staging}/${release}/modules/source"
    cp -a -- "$headers_dir" "${staging}/${release}/linux-headers"

    staging_bytes="$(du -bs -- "$staging" | awk '{ print $1 }')"
    file_count="$(find "$staging" | wc -l)"

    run_logged fakeroot -s "$fakeroot_state" -- chown -R 0:0 -- "$staging"
    run_logged fakeroot -i "$fakeroot_state" -- mke2fs -q -L '' -d "$staging" \
        -N "$((file_count + 4096))" -b 1024 -t ext4 "$image" "$(((staging_bytes + 256 * 1024 * 1024) / 1024))"
    run_logged qemu-img convert -O vhdx "$image" "$output"
    rm -rf -- "$staging" "$image" "$fakeroot_state"
}

create_modules_vhdx() {
    local output="${workspace}/modules.vhdx"
    local artifacts_script="${source_dir}/Microsoft/scripts/gen_artifacts_vhdx.sh"

    if [[ -f "$artifacts_script" ]]; then
        log "Building perf for the artifacts VHDX..."
        run_logged make -C "${source_dir}/tools/perf" -j"$jobs" \
            NO_JEVENTS=1 NO_JVMTI=1 NO_LIBTRACEEVENT=1 install DESTDIR="${workspace}/perf" prefix=/
        log "Creating modules VHDX with Microsoft/scripts/gen_artifacts_vhdx.sh..."
        run_logged env TMPDIR="$workspace" fakeroot -- bash "$artifacts_script" \
            "${workspace}/modules" "${workspace}/headers" "${workspace}/perf" "$kernel_release" "$output"
    else
        log "Creating modules VHDX with modules and headers..."
        create_artifacts_vhdx "${workspace}/modules" "${workspace}/headers" "$kernel_release" "$output" "$workspace"
    fi

    [[ -s "$output" ]] || fail "Modules VHDX was not created."
}

install_artifact() {
    local source=$1
    local destination=$2

    install -m 0644 -- "$source" "$destination" ||
        fail "Unable to write ${destination}. If WSL is running this kernel, choose another output directory."
    own_file_for_user "$destination"
}

install_artifacts() {
    local kernel_image="${source_dir}/arch/x86/boot/bzImage"

    [[ -f "$kernel_image" ]] || fail "Kernel build finished without producing ${kernel_image}."

    kernel_dest="${output_directory}/bzImage-${selected_version}"
    modules_dest="${output_directory}/modules-${selected_version}.vhdx"

    install_artifact "$kernel_image" "$kernel_dest"
    install_artifact "${workspace}/modules.vhdx" "$modules_dest"
    install_artifact "${source_dir}/.config" "${output_directory}/config-${selected_version}"

    log "Kernel ${kernel_release} written to ${output_directory}"
}

# Prints the escaped Windows form (C:\\dir\\file) of a path on a Windows
# drive, or nothing when the path lives inside the Linux filesystem.
escaped_windows_path() {
    local windows_path=""

    if command_exists wslpath; then
        windows_path="$(wslpath -w "$1" 2>/dev/null || true)"
    fi

    if [[ "$windows_path" =~ ^[A-Za-z]:\\ ]]; then
        printf '%s\n' "${windows_path//\\/\\\\}"
    fi
}

print_next_steps() {
    local kernel_windows modules_windows
    kernel_windows="$(escaped_windows_path "$kernel_dest")"
    modules_windows="$(escaped_windows_path "$modules_dest")"

    printf '\nArtifacts:\n  %s\n  %s\n  %s\n' "$kernel_dest" "$modules_dest" \
        "${output_directory}/config-${selected_version}"

    if [[ -z "$kernel_windows" || -z "$modules_windows" ]]; then
        cat <<EOF

WSL loads the kernel from the Windows filesystem. Copy both files to a
Windows directory, for example C:\\Users\\<you>\\WSL2, then add to
%UserProfile%\\.wslconfig:

  [wsl2]
  kernel=C:\\\\Users\\\\<you>\\\\WSL2\\\\bzImage-${selected_version}
  kernelModules=C:\\\\Users\\\\<you>\\\\WSL2\\\\modules-${selected_version}.vhdx
EOF
    else
        cat <<EOF

Add to %UserProfile%\\.wslconfig:

  [wsl2]
  kernel=${kernel_windows}
  kernelModules=${modules_windows}
EOF
    fi

    cat <<'EOF'

Then run 'wsl --shutdown' from Windows and confirm the new kernel with 'uname -r'.
EOF
}

run_wslconfig_generator() {
    local generator_path="${SCRIPT_DIR}/wslconfig-generator.sh"
    local -a generator_args=()
    local kernel_windows

    [[ -f "$generator_path" ]] || fail "Unable to find ${generator_path}."

    kernel_windows="$(escaped_windows_path "$kernel_dest")"
    if [[ -n "$kernel_windows" ]]; then
        generator_args+=(--kernel "$kernel_dest" --kernel-modules "$modules_dest")
    fi

    log "Launching the .wslconfig generator..."
    bash "$generator_path" "${generator_args[@]}"
    own_file_for_user "${PWD}/.wslconfig"
}

prompt_wslconfig_generation() {
    local choice

    case "$generate_wslconfig" in
        false)
            return
            ;;
        true)
            run_wslconfig_generator
            return
            ;;
        *) ;;
    esac

    [[ -t 0 ]] || return 0

    while true; do
        read -r -p "Run the .wslconfig generator now? (y/n): " choice
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

validate_version_format() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+){1,4}$ ]] || fail "Invalid version '$1'. Expected a tag version such as 6.18.54.1."
}

validate_series() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] || fail "Invalid series '$1'. Expected a series such as 6, 6.18 or 6.6."
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
            -V | --script-version)
                printf '%s\n' "$SCRIPT_VERSION"
                exit 0
                ;;
            -v | --version)
                require_value "$1" "$#"
                validate_version_format "$2"
                kernel_version="$2"
                shift 2
                ;;
            --series)
                require_value "$1" "$#"
                validate_series "$2"
                kernel_series="$2"
                series_requested="true"
                shift 2
                ;;
            -o | --output-directory)
                require_value "$1" "$#"
                output_directory="$2"
                shift 2
                ;;
            -c | --config)
                require_value "$1" "$#"
                [[ -f "$2" ]] || fail "Config file not found: $2"
                config_path="$(absolute_path "$2")"
                shift 2
                ;;
            -f | --fragment)
                require_value "$1" "$#"
                [[ -f "$2" ]] || fail "Config fragment not found: $2"
                extra_fragments+=("$(absolute_path "$2")")
                shift 2
                ;;
            --stock-config)
                use_bundled_fragment="false"
                shift
                ;;
            -j | --jobs)
                require_value "$1" "$#"
                [[ "$2" =~ ^[1-9][0-9]*$ ]] || fail "Job count must be a positive integer."
                jobs="$2"
                shift 2
                ;;
            -b | --build-dir)
                require_value "$1" "$#"
                build_parent="$2"
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
                fail "Unknown option: $1. Run '${SCRIPT_NAME} --help'."
                ;;
        esac
    done

    if [[ -n "$kernel_version" && "$series_requested" == "true" ]]; then
        fail "Use either --version or --series, not both."
    fi

    if [[ -z "$jobs" ]]; then
        jobs="$(nproc)"
    fi
}

main() {
    trap cleanup EXIT
    parse_args "$@"

    if [[ "$list_versions_only" == "true" ]]; then
        load_available_versions
        printf '%s\n' "$available_versions"
        return
    fi

    check_host
    prepare_output_directory
    check_build_location
    install_missing_packages
    if [[ -z "$kernel_version" && "$series_requested" == "false" && -t 0 ]]; then
        prompt_for_version_selection
    fi
    resolve_selected_version
    prepare_workspace
    download_source
    configure_kernel
    build_kernel
    create_modules_vhdx
    install_artifacts
    print_next_steps
    prompt_wslconfig_generation
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

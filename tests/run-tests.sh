#!/usr/bin/env bash
#
# Offline tests for build-kernel.sh and wslconfig-generator.sh. Each case
# runs in a subshell; the scripts are sourced (main does not run when sourced)
# or executed as a CLI.

# shellcheck source-path=SCRIPTDIR/..
set -Eeuo pipefail
IFS=$'\n\t'

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_DIR
readonly BUILD_SCRIPT="${REPO_DIR}/build-kernel.sh"
readonly GENERATOR="${REPO_DIR}/wslconfig-generator.sh"

TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "$TEST_TMP"' EXIT

passed=0
failed=0

pass() {
    passed=$((passed + 1))
    printf 'ok   %s\n' "$1"
}

flunk() {
    failed=$((failed + 1))
    printf 'FAIL %s\n' "$1"
    if [[ -n "${2-}" ]]; then
        printf '     %s\n' "$2"
    fi
}

# expect_ok <name> <command...>: command must exit 0.
expect_ok() {
    local name=$1
    shift
    local output
    if output="$("$@" 2>&1)"; then
        pass "$name"
    else
        flunk "$name" "unexpected failure: ${output}"
    fi
}

# expect_fail <name> <stderr substring> <command...>: command must exit
# non-zero and mention the substring.
expect_fail() {
    local name=$1
    local needle=$2
    shift 2
    local output
    if output="$("$@" 2>&1)"; then
        flunk "$name" "expected failure, got success: ${output}"
    elif [[ "$output" != *"$needle"* ]]; then
        flunk "$name" "missing '${needle}' in: ${output}"
    else
        pass "$name"
    fi
}

# expect_output <name> <expected stdout> <command...>
expect_output() {
    local name=$1
    local expected=$2
    shift 2
    local output
    if ! output="$("$@" 2>/dev/null)"; then
        flunk "$name" "command failed"
    elif [[ "$output" != "$expected" ]]; then
        flunk "$name" "expected [${expected}], got [${output}]"
    else
        pass "$name"
    fi
}

# Fake wslpath: /mnt/<d>/... maps to a drive, anything else to a UNC path.
FAKE_BIN="${TEST_TMP}/bin"
mkdir -p -- "$FAKE_BIN"
cat >"${FAKE_BIN}/wslpath" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "-w" ]] || exit 1
[[ "$2" != /mnt/f/* ]] || exit 1
if [[ "$2" =~ ^/mnt/([a-z])(/.*)?$ ]]; then
    rest="${BASH_REMATCH[2]:-/}"
    printf '%s:%s\n' "${BASH_REMATCH[1]^^}" "${rest//\//\\}"
else
    printf '\\\\wsl.localhost\\Ubuntu%s\n' "${2//\//\\}"
fi
EOF
chmod +x "${FAKE_BIN}/wslpath"

# ---------------------------------------------------------------- build-kernel.sh

in_build() {
    # shellcheck source=build-kernel.sh
    source "$BUILD_SCRIPT"
    "$@"
}

versions_fixture() {
    available_versions=$'6.18.54.1\n6.18.40.1\n6.6.123.2\n6.6.87.2\n5.15.167.4'
}

series_case() {
    versions_fixture
    latest_version_in_series "$1"
}

resolve_case() {
    versions_fixture
    kernel_version=$1
    kernel_series=$2
    resolve_selected_version
    printf '%s\n' "$selected_version"
}

parse_case() {
    parse_args "$@"
}

verify_case() {
    local final_config=$1
    local fragment=$2
    verify_config_fragments "$final_config" "$fragment"
}

windows_path_case() {
    PATH="${FAKE_BIN}:${PATH}"
    escaped_windows_path "$1"
}

expect_output "build: --script-version" "5.0.0" bash "$BUILD_SCRIPT" --script-version
expect_ok "build: --help" bash "$BUILD_SCRIPT" --help
expect_fail "build: unknown option" "Unknown option" bash "$BUILD_SCRIPT" --bogus
expect_fail "build: missing option value" "Missing value for --version" bash "$BUILD_SCRIPT" --version
expect_fail "build: malformed version" "Invalid version" bash "$BUILD_SCRIPT" --version '6.18;rm'
expect_fail "build: malformed series" "Invalid series" bash "$BUILD_SCRIPT" --series 6.x
expect_fail "build: version and series together" "either --version or --series" \
    bash "$BUILD_SCRIPT" --version 6.18.54.1 --series 6
expect_fail "build: zero jobs" "positive integer" bash "$BUILD_SCRIPT" --jobs 0
expect_fail "build: missing config file" "Config file not found" bash "$BUILD_SCRIPT" --config /nonexistent
expect_fail "build: missing fragment" "Config fragment not found" bash "$BUILD_SCRIPT" --fragment /nonexistent
expect_ok "build: valid options parse" in_build parse_case --series 6.6 --jobs 4 --stock-config --skip-wslconfig

expect_output "series: empty selects newest" "6.18.54.1" in_build series_case ""
expect_output "series: major 6" "6.18.54.1" in_build series_case 6
expect_output "series: 6.6" "6.6.123.2" in_build series_case 6.6
expect_output "series: 5" "5.15.167.4" in_build series_case 5
expect_fail "series: 6.1 must not match 6.18" "" in_build series_case 6.1
expect_output "resolve: exact version" "6.6.87.2" in_build resolve_case 6.6.87.2 ""
expect_output "resolve: series" "6.6.123.2" in_build resolve_case "" 6.6
expect_fail "resolve: unknown version" "is not an upstream tag" in_build resolve_case 6.6.1.1 ""
expect_fail "resolve: unknown series" "No upstream version matches series 7" in_build resolve_case "" 7

final_config="${TEST_TMP}/final.config"
cat >"$final_config" <<'EOF'
CONFIG_CAN=y
CONFIG_CAN_J1939=m
# CONFIG_DEBUG_INFO_BTF is not set
CONFIG_LOCALVERSION="-microsoft-standard-WSL2"
EOF
good_fragment="${TEST_TMP}/good.config"
cat >"$good_fragment" <<'EOF'
# comment
CONFIG_CAN=y
CONFIG_CAN_J1939=m
CONFIG_LOCALVERSION="-microsoft-standard-WSL2"
# CONFIG_DEBUG_INFO_BTF is not set
# CONFIG_SYMBOL_ABSENT_FROM_FINAL is not set
CONFIG_ALSO_ABSENT=n
EOF
printf 'CONFIG_CAN_J1939=y\n' >"${TEST_TMP}/downgraded.config"
printf 'CONFIG_CAN_NOT_A_SYMBOL=y\n' >"${TEST_TMP}/dropped.config"
printf '# CONFIG_CAN is not set\n' >"${TEST_TMP}/unset.config"
expect_ok "fragment: applied values pass" in_build verify_case "$final_config" "$good_fragment"
expect_fail "fragment: y requested, m applied" "CONFIG_CAN_J1939: requested y, got m" \
    in_build verify_case "$final_config" "${TEST_TMP}/downgraded.config"
expect_fail "fragment: dropped symbol" "CONFIG_CAN_NOT_A_SYMBOL: requested y, got n" \
    in_build verify_case "$final_config" "${TEST_TMP}/dropped.config"
expect_fail "fragment: unset requested, y applied" "CONFIG_CAN: requested n, got y" \
    in_build verify_case "$final_config" "${TEST_TMP}/unset.config"

bad_lines="$(grep -vnE '^(#.*|CONFIG_[A-Z0-9_]+=[ym]|# CONFIG_[A-Z0-9_]+ is not set|)$' "${REPO_DIR}/wsl-can.config" || true)"
if [[ -z "$bad_lines" ]]; then
    pass "fragment: wsl-can.config only holds y/m/unset assignments"
else
    flunk "fragment: wsl-can.config only holds y/m/unset assignments" "$bad_lines"
fi
duplicates="$(grep -oE '^(# )?CONFIG_[A-Z0-9_]+' "${REPO_DIR}/wsl-can.config" | sed 's/^# //' | sort | uniq -d)"
if [[ -z "$duplicates" ]]; then
    pass "fragment: wsl-can.config has no duplicate symbols"
else
    flunk "fragment: wsl-can.config has no duplicate symbols" "$duplicates"
fi

expect_fail "build dir: drvfs rejected" "Use a Linux filesystem" in_build require_supported_filesystem 9p "$TEST_TMP"
expect_fail "build dir: virtiofs rejected" "Use a Linux filesystem" in_build require_supported_filesystem virtiofs "$TEST_TMP"
expect_ok "build dir: ext4 accepted" in_build require_supported_filesystem ext4 "$TEST_TMP"
expect_output "windows path: drive path escaped" 'C:\\Users\\me\\bzImage-6.18.54.1' \
    in_build windows_path_case /mnt/c/Users/me/bzImage-6.18.54.1
expect_output "windows path: Linux path yields nothing" "" in_build windows_path_case /home/me/bzImage

artifacts_vhdx_case() {
    local root=$1
    local release="9.9.9-test"
    local image="${root}/check.img"
    local listing

    build_log="${root}/build.log"
    mkdir -p -- "${root}/modules/lib/modules/${release}/kernel/net/can" "${root}/headers/include/linux"
    printf 'kernel/net/can/can.ko:\n' >"${root}/modules/lib/modules/${release}/modules.dep"
    printf 'ko\n' >"${root}/modules/lib/modules/${release}/kernel/net/can/can.ko"
    ln -s /nonexistent/build "${root}/modules/lib/modules/${release}/build"
    ln -s /nonexistent/source "${root}/modules/lib/modules/${release}/source"
    printf '#define X 1\n' >"${root}/headers/include/linux/x.h"

    create_artifacts_vhdx "${root}/modules" "${root}/headers" "$release" "${root}/out.vhdx" "$root" >/dev/null
    qemu-img convert -O raw "${root}/out.vhdx" "$image"

    debugfs -R "stat /${release}/modules/modules.dep" "$image" >/dev/null 2>&1 ||
        fail "modules.dep missing from <release>/modules"
    debugfs -R "stat /${release}/linux-headers/include/linux/x.h" "$image" >/dev/null 2>&1 ||
        fail "linux-headers missing"
    for link in build source; do
        if debugfs -R "stat /${release}/modules/${link}" "$image" 2>/dev/null | grep -q 'Type: symlink'; then
            fail "${link} symlink was copied"
        fi
    done
    listing="$(debugfs -R "ls -l /${release}/modules/kernel/net/can" "$image" 2>/dev/null)"
    [[ "$listing" =~ \(1\)\ +0\ +0\ +[0-9]+\ .*can\.ko ]] || fail "can.ko is not root-owned: ${listing}"
    for leftover in vhdx-staging modules.img fakeroot.state; do
        [[ ! -e "${root}/${leftover}" ]] || fail "scratch file ${leftover} left behind"
    done
}

PATH="${PATH}:/usr/sbin:/sbin"
missing_tools=()
for tool in fakeroot mke2fs debugfs qemu-img; do
    command -v "$tool" >/dev/null 2>&1 || missing_tools+=("$tool")
done
if ((${#missing_tools[@]} == 0)); then
    mkdir -p -- "${TEST_TMP}/vhdx"
    expect_ok "vhdx: nested layout, root-owned, no build/source links" \
        in_build artifacts_vhdx_case "${TEST_TMP}/vhdx"
else
    printf 'SKIP vhdx: nested layout test needs:'
    printf ' %s' "${missing_tools[@]}"
    printf '\n'
fi

# ---------------------------------------------------------- wslconfig-generator.sh

in_generator() {
    # shellcheck source=wslconfig-generator.sh
    source "$GENERATOR"
    "$@"
}

with_fake_wslpath() {
    PATH="${FAKE_BIN}:${PATH}"
    "$@"
}

expect_output "path: backslash input" 'C:\\Users\\me\\bzImage' \
    in_generator normalize_windows_path 'C:\Users\me\bzImage'
expect_output "path: forward slash input" 'D:\\WSL\\modules.vhdx' \
    in_generator normalize_windows_path 'D:/WSL/modules.vhdx'
expect_output "path: already escaped input" 'C:\\Users\\me\\bzImage' \
    in_generator normalize_windows_path 'C:\\Users\\me\\bzImage'
expect_output "path: /mnt/c drive mapping" 'C:/Users/me/bzImage' \
    in_generator drive_mount_to_windows /mnt/c/Users/me/bzImage
expect_output "path: bare drive mount" 'E:/' in_generator drive_mount_to_windows /mnt/e
expect_output "path: non-mount path maps to nothing" "" in_generator drive_mount_to_windows /home/me/bzImage
expect_output "path: wslpath failure falls back to /mnt mapping" 'F:\\new\\bzImage' \
    in_generator with_fake_wslpath normalize_windows_path /mnt/f/new/bzImage
expect_output "path: /mnt/d with wslpath" 'D:\\k\\bzImage' \
    in_generator with_fake_wslpath normalize_windows_path /mnt/d/k/bzImage
expect_fail "path: UNC from Linux filesystem rejected" "must be on a Windows drive" \
    in_generator with_fake_wslpath normalize_windows_path /home/me/bzImage
expect_fail "path: relative path rejected" "must be on a Windows drive" \
    in_generator normalize_windows_path bzImage

expect_output "size: bare number" "24GB" in_generator normalize_size 24
expect_output "size: lower-case MB" "8192MB" in_generator normalize_size 8192mb
expect_output "size: zero" "0" in_generator normalize_size 0
expect_fail "size: invalid" "Invalid size" in_generator normalize_size 8TB
expect_output "reclaim: dropcache casing" "dropCache" in_generator normalize_auto_memory_reclaim DROPCACHE
expect_fail "reclaim: invalid" "Invalid auto memory reclaim" in_generator normalize_auto_memory_reclaim fast
expect_output "network: consomme" "consomme" in_generator normalize_networking_mode Consomme
expect_output "network: virtioproxy alias kept" "virtioproxy" in_generator normalize_networking_mode virtioproxy
expect_fail "network: bridged deprecated" "deprecated" in_generator normalize_networking_mode bridged
expect_fail "network: invalid" "Invalid networking mode" in_generator normalize_networking_mode wifi
expect_fail "bool: invalid" "Invalid boolean" in_generator normalize_boolean yes

expect_fail "generator: unknown option" "Unknown option" bash "$GENERATOR" --bogus
expect_fail "generator: missing value" "Missing value for --memory" bash "$GENERATOR" --memory
expect_fail "generator: zero memory" "Memory must be greater than zero" bash "$GENERATOR" --memory 0
expect_fail "generator: zero processors" "greater than zero" bash "$GENERATOR" --processors 0
expect_fail "generator: missing output directory" "Output directory does not exist" \
    bash "$GENERATOR" --output "${TEST_TMP}/missing/.wslconfig" --memory 8 --swap 2 --processors 4
expect_ok "generator: --help" bash "$GENERATOR" --help
expect_ok "generator: --examples" bash "$GENERATOR" --examples

generated="${TEST_TMP}/out/.wslconfig"
mkdir -p -- "${TEST_TMP}/out"
expect_ok "generator: explicit values" bash "$GENERATOR" --output "$generated" \
    --memory 16 --swap 0 --processors 08 --vm-idle-timeout 120 \
    --kernel 'C:\Users\me\WSL2\bzImage' --kernel-modules 'C:/Users/me/WSL2/modules.vhdx' \
    --networking-mode mirrored --auto-memory-reclaim gradual --sparse-vhd TRUE

expected_config="${TEST_TMP}/expected.wslconfig"
cat >"$expected_config" <<'EOF'
[wsl2]
# Custom Linux kernel image (bzImage) on the Windows filesystem.
kernel=C:\\Users\\me\\WSL2\\bzImage
# Modules VHDX built for that kernel.
kernelModules=C:\\Users\\me\\WSL2\\modules.vhdx
# VM memory limit.
memory=16GB
# Virtual processor count.
processors=8
# Swap size; 0 disables swap. The WSL default is 25% of host memory.
swap=0
# Swap VHDX location. The WSL default is %Temp%\swap.vhdx.
# swapFile=C:\\Users\\<your-user>\\AppData\\Local\\Temp\\swap.vhdx
# GUI support for Linux applications (WSLg).
guiApplications=true
# Console window with dmesg output at distro start (Windows 11).
debugConsole=false
# Nested virtualization inside WSL 2 (Windows 11).
nestedVirtualization=true
# Milliseconds before an idle VM shuts down (Windows 11).
vmIdleTimeout=120000
# Network mode: nat, mirrored, none or consomme.
networkingMode=mirrored
# Proxy DNS requests through Windows.
dnsTunneling=true
# Point Linux DNS at the NAT on the host (NAT mode only).
dnsProxy=true
# Let Windows Firewall and Hyper-V rules filter WSL traffic.
firewall=true
# Use the Windows HTTP proxy settings.
autoProxy=true

[experimental]
# Reclaim cached memory: disabled, gradual or dropCache.
autoMemoryReclaim=gradual
# Create new VHDs as sparse files.
sparseVhd=true
EOF
if diff -u "$expected_config" "$generated" >"${TEST_TMP}/diff.txt" 2>&1; then
    pass "generator: output matches expected .wslconfig"
else
    flunk "generator: output matches expected .wslconfig" "$(cat -- "${TEST_TMP}/diff.txt")"
fi

expect_ok "generator: rerun over existing file" bash "$GENERATOR" --output "$generated" \
    --memory 8 --swap 2 --processors 4
if [[ -f "${generated}.bak" ]] && grep -qx 'memory=16GB' "${generated}.bak" && grep -qx 'memory=8GB' "$generated"; then
    pass "generator: previous file kept as .bak"
else
    flunk "generator: previous file kept as .bak"
fi
leftovers="$(find "${TEST_TMP}/out" -name '.wslconfig.*' ! -name '.wslconfig.bak')"
if [[ -z "$leftovers" ]]; then
    pass "generator: no temporary files left behind"
else
    flunk "generator: no temporary files left behind" "$leftovers"
fi
if grep -qx 'autoMemoryReclaim=dropCache' "$generated" && grep -qx '# kernel=C:\\\\Users\\\\<your-user>\\\\WSL2\\\\bzImage' "$generated"; then
    pass "generator: documented defaults and placeholders"
else
    flunk "generator: documented defaults and placeholders" "$(cat -- "$generated")"
fi

if ! command -v powershell.exe >/dev/null 2>&1; then
    expect_fail "generator: hardware detection needs PowerShell" "Unable to locate powershell.exe" \
        bash "$GENERATOR" --output "${TEST_TMP}/out/detect.wslconfig"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
((failed == 0))

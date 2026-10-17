# WSL2 Kernel Build Script

Build Microsoft's WSL2 kernel from source with full CAN bus support, then generate a matching Windows `.wslconfig`. The build follows the steps in the [upstream README](https://github.com/microsoft/WSL2-Linux-Kernel) and produces the two files WSL loads: the kernel image (`kernel=`) and the modules VHDX (`kernelModules=`).

## Requirements

- WSL2 on x86_64 Windows with an Ubuntu or Debian distribution
- `sudo` access, used only to install missing build packages with `apt-get`
- 20 GB free on a Linux filesystem for the temporary build tree (default `/var/tmp`)
- Internet access to `github.com`

## Usage

Run the build as your regular user:

```sh
git clone https://github.com/slyfox1186/wsl2-kernel-build-script.git
cd wsl2-kernel-build-script
bash build-kernel.sh
```

In a terminal the script asks which version to build; otherwise it builds the newest upstream release. Common variations:

```sh
# Newest release of the 6.6 series, written straight to a Windows folder
bash build-kernel.sh --series 6.6 --output-directory /mnt/c/Users/you/WSL2

# An exact upstream tag
bash build-kernel.sh --version 6.18.54.1

# List the upstream tags
bash build-kernel.sh --list-versions
```

Run `bash build-kernel.sh --help` for every option, including `--jobs`, `--build-dir` and `--keep-build-dir`.

## Kernel configuration

The script starts from `Microsoft/config-wsl` of the exact version it builds, then merges config fragments with the kernel's `scripts/kconfig/merge_config.sh` and runs `make olddefconfig`. Because the base always matches the source tree, new kernel options get Microsoft's values instead of generic defaults.

The bundled fragment `wsl-can.config` enables the Linux CAN stack: raw, BCM, gateway, J1939, ISO-TP, vcan, vxcan, and the common PCI, ISA and USB controller drivers. It also disables BTF type information; delete that line from the fragment to keep Microsoft's default.

After configuration the script checks that every value in every fragment reached the final `.config`, and it stops with a list of any value Kconfig dropped.

| Option | Effect |
| --- | --- |
| `--fragment <path>` | Merge another fragment. Repeatable. |
| `--stock-config` | Skip the bundled CAN fragment. |
| `--config <path>` | Use a full `.config` as the base instead of Microsoft's. |

A fragment uses `.config` syntax. For example, this file adds the WireGuard module:

```text
CONFIG_WIREGUARD=m
```

## Output

The output directory receives:

| File | Purpose |
| --- | --- |
| `bzImage-<version>` | Kernel image for `kernel=` |
| `modules-<version>.vhdx` | Modules and kernel headers for `kernelModules=`; on 6.18 and later it also holds `perf` |
| `config-<version>` | The final kernel configuration |

The VHDX uses the `<release>/{modules,linux-headers,perf}` layout that current WSL mounts. Modules are installed without debug sections and every file is owned by root, as in the kernel Microsoft ships.

WSL reads both files from the Windows filesystem, so keep them on a Windows drive such as `C:\Users\<you>\WSL2`. Then point `%UserProfile%\.wslconfig` at them, using doubled backslashes:

```ini
[wsl2]
kernel=C:\\Users\\<you>\\WSL2\\bzImage-6.18.54.1
kernelModules=C:\\Users\\<you>\\WSL2\\modules-6.18.54.1.vhdx
```

Apply the change from PowerShell or Command Prompt, then check `uname -r` inside WSL:

```powershell
wsl --shutdown
```

Remove the two lines from `.wslconfig` to return to Microsoft's kernel.

## .wslconfig generator

`wslconfig-generator.sh` writes a `.wslconfig` from detected Windows memory and processor counts or from explicit values. It writes the common `[wsl2]` and `[experimental]` settings; the [WSL configuration reference](https://learn.microsoft.com/windows/wsl/wsl-config) lists the rest. If the output file already exists, the previous version is kept as `<file>.bak`.

```sh
bash wslconfig-generator.sh \
    --kernel /mnt/c/Users/you/WSL2/bzImage-6.18.54.1 \
    --kernel-modules /mnt/c/Users/you/WSL2/modules-6.18.54.1.vhdx
```

`build-kernel.sh --generate-wslconfig` runs it after a build and fills in both paths when the output directory is on a Windows drive. `.wslconfig.example` shows a complete file.

## Development

Lint both scripts with `shellcheck` and `shfmt`; shfmt reads its style from `.editorconfig`:

```sh
shellcheck build-kernel.sh wslconfig-generator.sh
shfmt --diff build-kernel.sh wslconfig-generator.sh
```

## References

- Microsoft WSL2 kernel source: <https://github.com/microsoft/WSL2-Linux-Kernel>
- WSL configuration reference: <https://learn.microsoft.com/windows/wsl/wsl-config>
- Kernel build requirements: <https://docs.kernel.org/process/changes.html>

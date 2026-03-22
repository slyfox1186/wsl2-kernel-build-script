# WSL2 Kernel Build Script

Build a custom Microsoft WSL2 kernel from source, then generate a matching Windows `.wslconfig` file. The project is intended for Debian or Ubuntu environments running inside WSL2.

## What Changed

- The build script now uses strict bash settings, safer temp directory handling, and a local `.wslconfig` generator instead of executing a remote script.
- Kernel version discovery now uses `git ls-remote` against the upstream Microsoft repository, not brittle HTML parsing and not the GitHub API.
- The `.wslconfig` generator now validates inputs, detects Windows hardware from PowerShell, and writes current settings into the correct `[wsl2]` and `[experimental]` sections.
- CI, linting, smoke tests, and basic repo hygiene files have been added.

## Requirements

- WSL2 on Windows with a Debian or Ubuntu distro
- `sudo` access inside the distro
- Internet access to download the upstream kernel source

The build script installs missing packages automatically with `apt-get`.

## Usage

Clone the repository and run the build:

```sh
git clone https://github.com/slyfox1186/wsl2-kernel-build-script.git
cd wsl2-kernel-build-script
sudo bash build-kernel.sh
```

Build a specific version:

```sh
sudo bash build-kernel.sh --version 6.6.87.2 --output-directory "$HOME/WSL2"
```

Build the latest kernel from a major series:

```sh
sudo bash build-kernel.sh --series 6 --skip-wslconfig
```

List upstream versions:

```sh
bash build-kernel.sh --list-versions
```

Generate only `.wslconfig`:

```sh
bash wslconfig-generator.sh --kernel /mnt/c/Users/you/WSL2/vmlinux
```

## Output

The kernel build produces `vmlinux` in your selected output directory. Store that file somewhere stable on Windows, for example:

```text
C:\Users\<your-user>\WSL2\vmlinux
```

Create `C:\Users\<your-user>\.wslconfig` and point `kernel=` at that file. A sample config lives at `.wslconfig.example`.

After updating the Windows config, apply the change from PowerShell or Command Prompt:

```powershell
wsl --shutdown
```

## Development

Run the local checks before pushing changes:

```sh
make lint
make smoke
```

## References

- Microsoft WSL2 kernel source: <https://github.com/microsoft/WSL2-Linux-Kernel/>
- Microsoft WSL configuration docs: <https://learn.microsoft.com/windows/wsl/wsl-config>

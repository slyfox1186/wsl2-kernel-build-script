#!/usr/bin/env bash

# Function to normalize paths
normalize_path() {
  local path="$1"
  # Replace any number of backslashes with two backslashes
  path="$(echo "$path" | sed -E 's/\\{1,}/\\\\/g')"
  echo "$path"
}

# Display the banner
echo "====================================================================="
echo "                     WSL Configuration Generator                    "
echo "====================================================================="
echo "This script generates a .wslconfig file based on your PC's specs and"
echo "allows you to customize various WSL settings. The generated file    "
echo "will be saved in the current directory.                             "
echo
echo "You can use command line arguments to set specific values for the   "
echo "non-determined variables. Run the script with -h or --help to see   "
echo "the available options.                                              "
echo "====================================================================="
echo

# Function to display the help menu
display_help() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -h, --help                                  Display this help menu"
    echo "  -e, --examples                              Display example values for non-determined variables"
    echo
    echo "  -k, --kernel                <path>          Set the kernel path"
    echo "  -f, --swapfile              <path>          Set the swapfile path"
    echo "  --auto-proxy                <boolean>       Enable or disable auto proxy (default: true)"
    echo "  --dns-tunneling             <boolean>       Enable or disable DNS tunneling (default: true)"
    echo "  --firewall                  <boolean>       Enable or disable the firewall (default: true)"
    echo "  --sparse-vhd                <boolean>       Enable or disable sparse VHD (default: true)"
    echo "  -d, --debug-console         <boolean>       Enable or disable debug console (default: false)"
    echo "  -g, --gui-applications      <boolean>       Enable or disable GUI applications support (WSLg) (default: true)"
    echo "  -n, --nested-virtualization <boolean>       Enable or disable nested virtualization (default: true)"
    echo "  -t, --vm-idle-timeout       <seconds>       Set the VM idle timeout in seconds (default: 900)"
    echo "  --auto-memory-reclaim       <option>        Set the auto memory reclaim option (disabled, gradual, sudden) (default: gradual)"
    echo "  --networking-mode           <option>        Set the networking mode (NAT, Bridged, Default) (default: NAT)"
    echo "  -m, --memory                <size>          Set the memory size in GB (overrides automatic detection)"
    echo "  -s, --swap                  <size>          Set the swap size in GB (overrides automatic detection)"
    echo "  -p, --processors            <number>        Set the number of processors (overrides automatic detection)"
    echo
    echo "Example: ./wsl-config-generator.sh --kernel \"C:\\\\Users\\\\jholl\\\\WSL2\\\\vmlinux\" -m 24 -p 8"
    echo
}

# Function to display example values
display_examples() {
  echo "Example values for non-determined variables:"
  echo
  echo "kernel=\"C:\\\\Users\\\\jholl\\\\WSL2\\\\vmlinux\""
  echo "memory=\"32\""
  echo "processors=\"8\""
  echo "swap=\"16\""
  echo "swapFile=\"C:\\\\Users\\\\jholl\\\\AppData\\\\Local\\\\Temp\\\\swap.vhdx\""
  echo "guiApplications=\"true\""
  echo "debugConsole=\"false\""
  echo "nestedVirtualization=\"true\""
  echo "vmIdleTimeout=\"900\""
  echo "autoMemoryReclaim=\"gradual\""
  echo "networkingMode=\"NAT\""
  echo "dnsTunneling=\"true\""
  echo "firewall=\"true\""
  echo "sparseVhd=\"true\""
  echo "autoProxy=\"true\""
  echo
}

# Default values
kernel_path=""
memory_value=""
num_processors=""
swap_size=""
swapfile_path=""
gui_applications="true"
debug_console="false"
nested_virtualization="true"
vm_idle_timeout="900"
auto_memory_reclaim="gradual"
networking_mode="NAT"
dns_tunneling="true"
firewall="true"
sparse_vhd="true"
auto_proxy="true"

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -k|--kernel)
      kernel_path=$(normalize_path "$2")
      shift ;;
    -m|--memory) memory_value="$2"; shift ;;
    -p|--processors) num_processors="$2"; shift ;;
    -s|--swap) swap_size="$2"; shift ;;
    -f|--swapfile)
      swapfile_path=$(normalize_path "$2")
      shift ;;
    -g|--gui-applications)
      case $2 in
        true|false) gui_applications="$2" ;;
        *) echo "Invalid value for --gui-applications. Use 'true' or 'false'."; exit 1 ;;
      esac
      shift ;;
    -d|--debug-console)
      case $2 in
        true|false) debug_console="$2" ;;
        *) echo "Invalid value for --debug-console. Use 'true' or 'false'."; exit 1 ;;
      esac
      shift ;;
    -n|--nested-virtualization)
      case $2 in
        true|false) nested_virtualization="$2" ;;
        *) echo "Invalid value for --nested-virtualization. Use 'true' or 'false'."; exit 1 ;;
      esac
      shift ;;
    -t|--vm-idle-timeout) vm_idle_timeout="$2"; shift ;;
    --auto-memory-reclaim)
      case $2 in
        disabled|gradual|sudden) auto_memory_reclaim="$2" ;;
        *) echo "Invalid value for --auto-memory-reclaim. Use 'disabled', 'gradual', or 'sudden'."; exit 1 ;;
      esac
      shift ;;
    --networking-mode)
      case $2 in
        NAT|Bridged|Default) networking_mode="$2" ;;
        *) echo "Invalid value for --networking-mode. Use 'NAT', 'Bridged', or 'Default'."; exit 1 ;;
      esac
      shift ;;
    --dns-tunneling)
      case $2 in
        true|false) dns_tunneling="$2" ;;
        *) echo "Invalid value for --dns-tunneling. Use 'true' or 'false'."; exit 1 ;;
      esac
      shift ;;
    --firewall)
      case $2 in
        true|false) firewall="$2" ;;
        *) echo "Invalid value for --firewall. Use 'true' or 'false'."; exit 1 ;;
      esac
      shift ;;
    --sparse-vhd)
      case $2 in
        true|false) sparse_vhd="$2" ;;
        *) echo "Invalid value for --sparse-vhd. Use 'true' or 'false'."; exit 1 ;;
      esac
      shift ;;
    --auto-proxy)
      case $2 in
        true|false) auto_proxy="$2" ;;
        *) echo "Invalid value for --auto-proxy. Use 'true' or 'false'."; exit 1 ;;
      esac
      shift ;;
    -e|--examples) display_examples; exit 0 ;;
    -h|--help) display_help; exit 0 ;;
    *) echo "Unknown option: $1"; display_help; exit 1 ;;
  esac
  shift
done

# Define the path to powershell.exe
if [[ -d "/c/Windows/System32/WindowsPowerShell/v1.0" ]]; then
    pwsh_path="/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
elif [[ -d "/mnt/c/Windows/System32/WindowsPowerShell/v1.0" ]]; then
    pwsh_path="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
else
    echo "The script failed to located the file powershell.exe."
    echo "Please change the variable \"\pwsh_path\" and point it to this file to continue."
    exit 1
fi

# Get total physical memory in GB from Windows using PowerShell
if [[ -z "$memory_value" ]]; then
  total_memory_gb=$("$pwsh_path" -NoL -NoP -C "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB" | tr -d '\r')

  # Round down to the nearest integer
  total_memory_gb=${total_memory_gb%.*}

  if [[ ! $total_memory_gb =~ ^[0-9]+$ ]]; then
      echo "Failed to retrieve total physical memory. Using default value of 0."
      total_memory_gb=0
  fi

  # Calculate the memory value based on the total physical memory
  if [[ $total_memory_gb -gt 64 ]]; then
      memory_value=48
  elif [[ $total_memory_gb -eq 64 ]]; then
      memory_value=32
  elif [[ $total_memory_gb -ge 48 && $total_memory_gb -lt 64 ]]; then
      memory_value=24
  elif [[ $total_memory_gb -ge 32 && $total_memory_gb -lt 48 ]]; then
      memory_value=16
  elif [[ $total_memory_gb -ge 16 && $total_memory_gb -lt 32 ]]; then
      memory_value=8
  elif [[ $total_memory_gb -ge 8 && $total_memory_gb -lt 16 ]]; then
      memory_value=4
  elif [[ $total_memory_gb -lt 4 ]]; then
      echo "Error: Insufficient memory. The script requires at least 4GB of RAM."
      exit 1
  fi
fi

# Get number of processors
if [[ -z "$num_processors" ]]; then
  num_processors=$(nproc --all)
fi

# Calculate the swap size as 25% of the total memory if not provided by the user
if [[ -z "$swap_size" ]]; then
  swap_size=$(awk "BEGIN {printf \"%.0f\", ${total_memory_gb} * 0.25}")
fi

# Convert VM idle timeout from seconds to milliseconds
vm_idle_timeout_ms=$((vm_idle_timeout * 1000))

# Create the .wslconfig file with filled in values
cat > .wslconfig <<EOL
[wsl2]
# Specify a custom Linux kernel to use with your installed distros. The default kernel used can be found at https://github.com/microsoft/WSL2-Linux-Kernel
kernel=${kernel_path:-C:\\\\path\\\\to\\\\vmlinux}
# Limits VM memory to use no more than 4 GB, this can be set as whole numbers using GB or MB
# Total memory: ${total_memory_gb}GB
# Setting memory to: ${memory_value}GB
memory=${memory_value}GB
# Sets the VM virtual processors count
processors=${num_processors}
# Sets amount of swap storage space, default is 25% of available RAM
swap=${swap_size}GB
# Sets swapfile path location, default is %LocalAppData%\\temp\\swap.vhdx
# swapFile=${swapfile_path:-C:\\\\path\\\\to\\\\swap\\\\file\\\\swap.vhdx}
# Boolean to turn on or off support for GUI applications (WSLg) in WSL. Only available for Windows 11
guiApplications=${gui_applications}
# Turns on or off output console showing contents of dmesg when opening a WSL 2 distro for debugging
debugConsole=${debug_console}
# Enables nested virtualization
nestedVirtualization=${nested_virtualization}
# The number of milliseconds that a VM is idle, before it is shut down. Only available for Windows 11
vmIdleTimeout=${vm_idle_timeout_ms}

# Enable experimental features
[experimental]
autoMemoryReclaim=${auto_memory_reclaim}
networkingMode=${networking_mode}
dnsTunneling=${dns_tunneling}
firewall=${firewall}
sparseVhd=${sparse_vhd}
autoProxy=${auto_proxy}
EOL

# Display the contents of the .wslconfig file
printf "\n%s\n\n" "Generated .wslconfig file:"
cat .wslconfig

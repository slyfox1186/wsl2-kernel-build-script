# Windows WSL2 Kernel Build Script

## Overview

This document details the process of building the latest Microsoft WSL2 (Windows Subsystem for Linux 2) kernel from source. The source code is available on Microsoft's official [GitHub page](https://github.com/microsoft/WSL2-Linux-Kernel/). This guide is specifically designed for users looking to update their WSL2 kernels for Debian or Ubuntu distributions running on x86_64 architecture.

### Purpose

- To compile and integrate the latest Microsoft WSL2 kernel release with your current Linux distributions on WSL2.

### Supported Distributions

- Debian / Ubuntu

#### Supported Architecture

- x86_64

### Installation Instructions

There are two methods to download and run the build script:

- **Direct Download and Execution:**

  - Download and execute the script in one step:
    ```sh
    curl -Lso build-kernel.sh https://wsl.optimizethis.net
    sudo bash build-kernel.sh
    ```
  
  - Clone the repository and execute the build script:
    ```sh
    git clone https://github.com/slyfox1186/wsl2-kernel-build-script.git
    cd wsl2-kernel-build-script
    sudo bash build-kernel.sh
    ```

- **Download Link for the Script:**

  If you prefer manually downloading the script before executing, use this [direct download link for the build script](https://wsl.optimizethis.net).

### Post-Installation Steps

1. **Kernel File Relocation:**

   The build script outputs a new kernel file named `vmlinux`. Move this file to a directory within your Windows user profile path. Example location:
   
   ```batch
   %USERPROFILE%\WSL2\vmlinux
   ```

2. **WSL Configuration:**

   To use the new kernel, create a `.wslconfig` file at `%USERPROFILE%\.wslconfig` and configure it to point to your new kernel file. Detailed instructions and configuration options can be found in the [WSL configuration guide](https://learn.microsoft.com/en-us/windows/wsl/wsl-config).

   A sample `.wslconfig` file to get started can be found [here](https://github.com/slyfox1186/windows-wsl2-kernel-build-script/blob/main/.wslconfig).

### Additional Resources

- For more information on `.wslconfig` options, please consult the [Microsoft Documentation](https://learn.microsoft.com/en-us/windows/wsl/wsl-config).

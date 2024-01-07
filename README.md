# Windows WSL2 Kernel Build Script

## Build the latest released kernel from Microsoft's [GitHub](https://github.com/microsoft/WSL2-Linux-Kernel/) Page

###  Purpose
  - Build the latest Microsoft WSL2 kernel release to link to your current distros.

### Supported Distros:
  - Debian / Ubuntu

####  Supported architecture
  - x86_x64

###  Install info
  - Run the below command in your WSL window
  ```bash
  curl -Lso build-kernel https://wsl2-kernel.optimizethis.net
  sudo bash build-kernel
  ```
  - You can also clone the repo
  ```bash
  git clone https://github.com/slyfox1186/wsl2-kernel-build-script.git
  cd wsl2-kernel-build-script
  sudo bash build-kernel
  ```
  
  - The new kernel will be moved to the same directory as the install script `build-kernel`
    - The filename will be: `vmlinux`
  - Place the file `vmlinux` into a folder inside the Windows directory `%USERPROFILE%`
    - I placed mine into a folder I created called `%USERPROFILE%\WSL2\vmlinux`

  - Next, create a file called `%USERPROFILE%\.wslconfig`
   
  - Now, visit the below website for instructions on how to link the kernel to WSL2 
    - https://learn.microsoft.com/en-us/windows/wsl/wsl-config

  - An example of the `.wslconfig` file is [.wslconfig script](https://github.com/slyfox1186/windows-wsl2-kernel-build-script/blob/main/.wslconfig). You can use it to help understand the file formatting.

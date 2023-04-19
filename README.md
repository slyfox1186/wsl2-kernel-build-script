# Windows-WSL2-Kernel-build-script
## Build the latest released kernel from Microsoft's GitHub Page

###  Purpose
  - Build the latest Microsoft WSL2 kernel release to link to your current distros.

### Supported Distros:
  - Debian-based ( Ubuntu, etc. )

####  Supported architecture
  - x86_x64

###  Install info
  - The new kernel will be located in the root build directory
    - The filename will be: vmlinux
  - Place the file vmlinux into a folder inside Windows `%USERPROFILE%`
    - I placed mine into the folder I created called `%USERPROFILE%\WSL2\vmlinux`

  - Create a file called `%USERPROFILE%\.wslconfig`
   
  - Visit the below website for instructions on how to link the kernel to WSL2
    - https://learn.microsoft.com/en-us/windows/wsl/wsl-config

# Azure Linux 4 ISO Maker

A comprehensive shell script to create UEFI-bootable live ISO images for Azure Linux 4, supporting both **x86_64** and **aarch64** architectures.

## Overview

Azure Linux 4 is a Fedora-based, RPM-based Linux distribution optimized for the cloud. Since it does not provide a standalone installer ISO out of the box for all scenarios, this project allows you to build custom Live ISOs directly from the official Microsoft RPM repositories.

The generated ISOs use a UEFI Secure Boot compatible bootchain (`shim` + `grub2`) and boot a SquashFS live image of the root filesystem.

## Building with GitHub Actions (Recommended)

This repository includes a GitHub Actions workflow that automatically builds the ISOs in the cloud.

1. Fork or push this repository to GitHub.
2. Go to the **Actions** tab.
3. Select the **Build Azure Linux 4 ISOs** workflow.
4. Click **Run workflow** (you can optionally specify the target architecture or extra packages).
5. Once the workflow completes, the ISO files will be available as downloadable artifacts.

## Building Locally with Docker

To avoid installing host dependencies, this project is fully containerized using Docker.

### Prerequisites
- [Docker](https://docs.docker.com/get-docker/) installed and running.
- `make` (optional, for convenience).

### Quick Start

1. Clone or download this repository.
2. Build the Docker builder image and run the build:
   ```bash
   make docker-build
   ```

By default, the script builds ISOs for **both** `x86_64` and `aarch64`, saving them to the `./output` directory.

> **Note:** The Docker container runs with `--privileged` because the script requires `mount` and `chroot` capabilities to assemble the root filesystem and run `dracut`.

### Advanced Docker Usage

You can pass arguments to the underlying script via the `ARGS` variable in `make`:

```bash
# Build only the x86_64 ISO with extra packages
make docker-build ARGS="--arch x86_64 --packages nginx,curl"

# Clean up output and build directories
make clean
```

## Configuration

Configuration is managed via `config/default.conf` and the package list files.

### Package Profiles

You can choose between different package profiles in `default.conf` (`PACKAGE_PROFILE` variable):
- **core**: A minimal functional system (kernel, networking, ssh, systemd). See `config/packages-core.list`.
- **full**: Extends core with development tools (gcc, git, python3), editors (vim, tmux), and diagnostic tools. See `config/packages-full.list`.

## Building Locally Without Docker (Advanced)

If you prefer to run the script directly on your host machine, it must be a Linux host (e.g., Ubuntu, Fedora, or Azure Linux) as it requires `root` privileges and Linux-specific tools.

**Required Packages:** `xorriso`, `squashfs-tools`, `dosfstools`, `mtools`, `dracut`, `dnf` or `tdnf`.
**For cross-architecture (aarch64 on x86):** `qemu-user-static`.

```bash
sudo ./build-azl4-iso.sh --arch all
```

## Booting the ISO

The resulting ISOs are UEFI-only (no legacy BIOS support). 

### QEMU (Testing)

**x86_64:**
```bash
qemu-system-x86_64 -m 2048 -cdrom output/azurelinux-4.0-x86_64.iso \
  -bios /usr/share/OVMF/OVMF_CODE.fd -boot d
```

**aarch64:**
```bash
qemu-system-aarch64 -M virt -cpu max -m 2048 \
  -cdrom output/azurelinux-4.0-aarch64.iso \
  -bios /usr/share/AAVMF/AAVMF_CODE.fd -boot d
```

#!/usr/bin/env bash
# Azure Linux 4 ISO Maker
# Creates UEFI-bootable live ISO images for x86_64 and aarch64.

set -euo pipefail

# --- Constants & Globals ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config/default.conf"
TARGET_ARCH="all"
EXTRA_PKG_ARGS=""
VERBOSE=0
DRY_RUN=0
CLEAN=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Functions ---
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
die() { log_err "$1"; exit 1; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]
Azure Linux 4 ISO Maker

Options:
  --arch <arch>      Target architecture: x86_64, aarch64, or all (default: all)
  --config <file>    Path to config file (default: config/default.conf)
  --packages <list>  Comma-separated list of extra packages to install
  --output-dir <dir> Output directory for ISOs
  --clean            Clean build directories before starting
  --verbose          Enable verbose output
  --dry-run          Check dependencies and print what would be done
  -h, --help         Show this help message
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --arch) TARGET_ARCH="$2"; shift 2 ;;
            --config) CONFIG_FILE="$2"; shift 2 ;;
            --packages) EXTRA_PKG_ARGS="$2"; shift 2 ;;
            --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
            --clean) CLEAN=1; shift ;;
            --verbose) VERBOSE=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        die "Config file not found: $CONFIG_FILE"
    fi
    log_info "Loading config from $CONFIG_FILE"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
}

check_dependencies() {
    local deps=(xorriso mksquashfs mkfs.fat mcopy dracut)
    
    # check for dnf or tdnf
    if command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
    elif command -v tdnf >/dev/null 2>&1; then
        PKG_MGR="tdnf"
    else
        die "Neither dnf nor tdnf found on the host system."
    fi
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            die "Missing required tool: $dep"
        fi
    done
    
    # Check architecture-specific requirements (qemu-user-static)
    HOST_ARCH=$(uname -m)
    if [[ "$TARGET_ARCH" == "aarch64" || "$TARGET_ARCH" == "all" ]]; then
        if [[ "$HOST_ARCH" != "aarch64" ]]; then
            if ! command -v qemu-aarch64-static >/dev/null 2>&1; then
                log_warn "Host is $HOST_ARCH but target includes aarch64. 'qemu-aarch64-static' (or similar qemu-user-static package) is required for chroot."
            fi
        fi
    fi
    
    if [[ "$EUID" -ne 0 && "$DRY_RUN" -eq 0 ]]; then
        die "This script requires root privileges to build the rootfs. Please run with sudo."
    fi
}

get_package_list() {
    local profile_file="${SCRIPT_DIR}/config/packages-${PACKAGE_PROFILE}.list"
    if [[ ! -f "$profile_file" ]]; then
        die "Package profile not found: $profile_file"
    fi
    
    local pkgs=()
    
    # If full, also include core
    if [[ "$PACKAGE_PROFILE" == "full" ]]; then
        local core_file="${SCRIPT_DIR}/config/packages-core.list"
        if [[ -f "$core_file" ]]; then
            while read -r line; do
                [[ -z "$line" || "$line" == \#* ]] && continue
                pkgs+=("$line")
            done < "$core_file"
        fi
    fi
    
    while read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        pkgs+=("$line")
    done < "$profile_file"
    
    # Add extra packages from config
    for pkg in $EXTRA_PACKAGES; do
        pkgs+=("$pkg")
    done
    
    # Add extra packages from CLI arguments
    if [[ -n "$EXTRA_PKG_ARGS" ]]; then
        IFS=',' read -ra extra_args <<< "$EXTRA_PKG_ARGS"
        for pkg in "${extra_args[@]}"; do
            pkgs+=("$pkg")
        done
    fi
    
    # Print as space-separated list
    echo "${pkgs[@]}"
}

setup_repo() {
    local rootfs="$1"
    local arch="$2"
    local basearch="$arch"
    
    mkdir -p "${rootfs}/etc/yum.repos.d"
    
    local repo_url="${REPO_BASEURL//\$basearch/$basearch}"
    
    cat > "${rootfs}/etc/yum.repos.d/azurelinux.repo" <<EOF
[azurelinux-3-0]
name=Azure Linux 3.0
baseurl=$repo_url
enabled=1
gpgcheck=$REPO_GPGCHECK
gpgkey=$REPO_GPGKEY
EOF
}

build_rootfs() {
    local arch="$1"
    local work_dir="${BUILD_DIR}/${arch}"
    local rootfs="${work_dir}/rootfs"
    
    log_info "Building rootfs for $arch in $rootfs"
    
    if [[ "$DRY_RUN" -eq 1 ]]; then
        return
    fi
    
    mkdir -p "$rootfs"
    
    setup_repo "$rootfs" "$arch"
    
    local pkgs
    pkgs=$(get_package_list)
    
    log_info "Installing packages into rootfs..."
    local dnf_cmd=("$PKG_MGR" install -y --installroot="$rootfs" --releasever=3.0 --nogpgcheck --setopt=install_weak_deps=False)
    
    # Execute package installation
    if [[ "$VERBOSE" -eq 1 ]]; then
        "${dnf_cmd[@]}" ${pkgs}
    else
        "${dnf_cmd[@]}" ${pkgs} > "${work_dir}/dnf.log" 2>&1 || {
            cat "${work_dir}/dnf.log"
            die "Package installation failed."
        }
    fi
    
    # Configure system
    log_info "Configuring system settings..."
    echo "$DEFAULT_HOSTNAME" > "${rootfs}/etc/hostname"
    echo "LANG=$DEFAULT_LOCALE" > "${rootfs}/etc/locale.conf"
    
    ln -sf "/usr/share/zoneinfo/$DEFAULT_TIMEZONE" "${rootfs}/etc/localtime"
    
    # Setup root password
    if [[ -n "$DEFAULT_ROOT_PASSWORD" ]]; then
        sed -i "s|^root:.*|root:${DEFAULT_ROOT_PASSWORD}:18000:0:99999:7:::|" "${rootfs}/etc/shadow"
    fi
    
    # Allow empty root password for live console
    if [[ "$ALLOW_ROOT_AUTOLOGIN" == "yes" ]]; then
        sed -i 's/^root:\*:/root::/' "${rootfs}/etc/shadow"
    fi
    
    # fstab
    cat > "${rootfs}/etc/fstab" <<EOF
# Live OS fstab
EOF

    # Enable services if systemctl exists in chroot
    if [[ -x "${rootfs}/usr/bin/systemctl" ]]; then
        log_info "Enabling essential services..."
        chroot "$rootfs" /usr/bin/systemctl enable systemd-networkd systemd-resolved sshd || true
    fi
    
    # Clean up dnf cache inside rootfs
    chroot "$rootfs" $PKG_MGR clean all || true
    rm -rf "${rootfs}/var/cache/dnf"/* "${rootfs}/var/cache/tdnf"/*
}

build_initramfs() {
    local arch="$1"
    local work_dir="${BUILD_DIR}/${arch}"
    local rootfs="${work_dir}/rootfs"
    
    log_info "Generating initramfs for live boot..."
    
    if [[ "$DRY_RUN" -eq 1 ]]; then
        return
    fi
    
    # Find installed kernel version
    local kver
    kver=$(ls -1 "${rootfs}/lib/modules" | head -n 1)
    
    if [[ -z "$kver" ]]; then
        die "No kernel modules found in rootfs"
    fi
    
    log_info "Found kernel version: $kver"
    
    # Create initramfs with dracut in chroot
    local initramfs_file="/boot/initramfs-${kver}.img"
    
    # Mount special filesystems for chroot
    mount -t proc proc "${rootfs}/proc"
    mount -t sysfs sys "${rootfs}/sys"
    mount -o bind /dev "${rootfs}/dev"
    
    chroot "$rootfs" dracut --nomdadmconf --nolvmconf --xz --add "$DRACUT_MODULES" --force "$initramfs_file" "$kver" || {
        umount "${rootfs}/dev" || true
        umount "${rootfs}/sys" || true
        umount "${rootfs}/proc" || true
        die "Dracut failed."
    }
    
    umount "${rootfs}/dev" "${rootfs}/sys" "${rootfs}/proc"
}

build_squashfs() {
    local arch="$1"
    local work_dir="${BUILD_DIR}/${arch}"
    local rootfs="${work_dir}/rootfs"
    local iso_dir="${work_dir}/iso_root"
    local liveos_dir="${iso_dir}/LiveOS"
    
    log_info "Creating SquashFS live image..."
    
    if [[ "$DRY_RUN" -eq 1 ]]; then
        return
    fi
    
    mkdir -p "$liveos_dir"
    
    local out_img="${liveos_dir}/squashfs.img"
    if [[ -f "$out_img" ]]; then
        rm -f "$out_img"
    fi
    
    local mksquashfs_args=(-comp "$SQUASHFS_COMPRESSION" -noappend)
    if [[ "$VERBOSE" -eq 0 ]]; then
        mksquashfs_args+=(-no-progress)
    fi
    
    mksquashfs "$rootfs" "$out_img" "${mksquashfs_args[@]}"
}

build_efi_boot() {
    local arch="$1"
    local work_dir="${BUILD_DIR}/${arch}"
    local rootfs="${work_dir}/rootfs"
    local iso_dir="${work_dir}/iso_root"
    local efi_boot_dir="${iso_dir}/EFI/BOOT"
    local images_dir="${iso_dir}/images"
    
    log_info "Configuring UEFI boot for $arch..."
    
    if [[ "$DRY_RUN" -eq 1 ]]; then
        return
    fi
    
    mkdir -p "$efi_boot_dir" "$images_dir"
    
    local shim_src grub_src boot_efi grub_efi
    
    if [[ "$arch" == "x86_64" ]]; then
        shim_src="${rootfs}/boot/efi/EFI/azurelinux/shimx64.efi"
        grub_src="${rootfs}/boot/efi/EFI/azurelinux/grubx64.efi"
        boot_efi="BOOTX64.EFI"
        grub_efi="grubx64.efi"
    elif [[ "$arch" == "aarch64" ]]; then
        shim_src="${rootfs}/boot/efi/EFI/azurelinux/shimaa64.efi"
        grub_src="${rootfs}/boot/efi/EFI/azurelinux/grubaa64.efi"
        boot_efi="BOOTAA64.EFI"
        grub_efi="grubaa64.efi"
    else
        die "Unsupported arch: $arch"
    fi
    
    # Azure Linux shim and grub might be placed in slightly different locations based on package layout.
    # Let's search if they are not in the exact hardcoded path.
    if [[ ! -f "$shim_src" ]]; then
        shim_src=$(find "${rootfs}/boot" "${rootfs}/usr" -name "shim*${arch/x86_64/x64}*.efi" -o -name "shim*${arch/aarch64/aa64}*.efi" | head -n 1)
    fi
    
    if [[ ! -f "$grub_src" ]]; then
        grub_src=$(find "${rootfs}/boot" "${rootfs}/usr" -name "grub*${arch/x86_64/x64}*.efi" -o -name "grub*${arch/aarch64/aa64}*.efi" | head -n 1)
    fi
    
    if [[ -z "$shim_src" || ! -f "$shim_src" ]]; then
        log_warn "shim EFI binary not found, boot may not work"
    else
        cp "$shim_src" "${efi_boot_dir}/${boot_efi}"
    fi
    
    if [[ -z "$grub_src" || ! -f "$grub_src" ]]; then
        log_warn "grub EFI binary not found, boot may not work"
    else
        cp "$grub_src" "${efi_boot_dir}/${grub_efi}"
    fi
    
    # Kernel & Initrd
    local kver
    kver=$(ls -1 "${rootfs}/lib/modules" | head -n 1)
    cp "${rootfs}/boot/vmlinuz-${kver}" "${iso_dir}/vmlinuz"
    cp "${rootfs}/boot/initramfs-${kver}.img" "${iso_dir}/initrd.img"
    
    # grub.cfg
    cat > "${efi_boot_dir}/grub.cfg" <<EOF
set default="0"
set timeout=5

menuentry 'Azure Linux 4.0 Live ($arch)' {
    linux /vmlinuz root=live:CDLABEL=${ISO_VOLUME_LABEL} rd.live.image quiet
    initrd /initrd.img
}
EOF
    
    # Create FAT32 EFI boot image
    local efi_img="${images_dir}/efiboot.img"
    
    # Create empty image
    dd if=/dev/zero of="$efi_img" bs=1M count="$EFI_IMG_SIZE_MB" status=none
    mkfs.fat -F 32 -n EFI_BOOT "$efi_img" >/dev/null
    
    # Copy files into EFI image
    mcopy -i "$efi_img" -s "${iso_dir}/EFI" ::/
}

build_iso() {
    local arch="$1"
    local work_dir="${BUILD_DIR}/${arch}"
    local iso_dir="${work_dir}/iso_root"
    local output_iso="${OUTPUT_DIR}/azurelinux-4.0-${arch}.iso"
    
    log_info "Assembling ISO for $arch..."
    
    if [[ "$DRY_RUN" -eq 1 ]]; then
        return
    fi
    
    mkdir -p "$OUTPUT_DIR"
    
    local xorriso_args=(
        -as mkisofs
        -iso-level 3
        -full-iso9660-filenames
        -volid "${ISO_VOLUME_LABEL}"
        -appid "${ISO_APPLICATION}"
        -publisher "${ISO_PUBLISHER}"
        -eltorito-alt-boot
        -e images/efiboot.img
        -no-emul-boot
        -isohybrid-gpt-basdat
        -output "$output_iso"
        "$iso_dir"
    )
    
    if [[ "$VERBOSE" -eq 0 ]]; then
        xorriso "${xorriso_args[@]}" > "${work_dir}/xorriso.log" 2>&1 || {
            cat "${work_dir}/xorriso.log"
            die "xorriso failed"
        }
    else
        xorriso "${xorriso_args[@]}"
    fi
    
    log_info "ISO successfully built: $output_iso"
}

cleanup() {
    if [[ "$CLEAN" -eq 1 ]]; then
        log_info "Cleaning build directory..."
        if [[ -d "$BUILD_DIR" && "$DRY_RUN" -eq 0 ]]; then
            # Unmount any stray mounts first
            for arch in x86_64 aarch64; do
                if mountpoint -q "${BUILD_DIR}/${arch}/rootfs/proc" 2>/dev/null; then umount "${BUILD_DIR}/${arch}/rootfs/proc"; fi
                if mountpoint -q "${BUILD_DIR}/${arch}/rootfs/sys" 2>/dev/null; then umount "${BUILD_DIR}/${arch}/rootfs/sys"; fi
                if mountpoint -q "${BUILD_DIR}/${arch}/rootfs/dev" 2>/dev/null; then umount "${BUILD_DIR}/${arch}/rootfs/dev"; fi
            done
            rm -rf "$BUILD_DIR"
        fi
    fi
}

process_arch() {
    local arch="$1"
    log_info "=== Starting build for $arch ==="
    
    # In order to build properly, make sure directories are clean or ready
    mkdir -p "${BUILD_DIR}/${arch}"
    
    build_rootfs "$arch"
    build_initramfs "$arch"
    build_squashfs "$arch"
    build_efi_boot "$arch"
    build_iso "$arch"
    
    log_info "=== Completed build for $arch ==="
}

main() {
    parse_args "$@"
    load_config
    check_dependencies
    
    cleanup
    
    # To use relative paths based on CWD
    if [[ "$DRY_RUN" -eq 0 ]]; then
        mkdir -p "$OUTPUT_DIR"
        mkdir -p "$BUILD_DIR"
        OUTPUT_DIR="$(realpath -m "$OUTPUT_DIR")"
        BUILD_DIR="$(realpath -m "$BUILD_DIR")"
    fi
    
    local archs=()
    if [[ "$TARGET_ARCH" == "all" ]]; then
        archs=("x86_64" "aarch64")
    else
        archs=("$TARGET_ARCH")
    fi
    
    for a in "${archs[@]}"; do
        process_arch "$a"
    done
    
    if [[ "$DRY_RUN" -eq 0 ]]; then
        log_info "All done! Generated ISOs:"
        ls -lh "${OUTPUT_DIR}"/*.iso 2>/dev/null || true
        
        log_info "SHA256 Checksums:"
        (cd "$OUTPUT_DIR" && sha256sum *.iso 2>/dev/null) || true
    fi
}

main "$@"

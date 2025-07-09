#!/bin/bash
set -e

# Re-run with sudo if not already root
if [ "$EUID" -ne 0 ]; then
  echo "[INFO] Re-running script with sudo..."
  exec sudo "$0" "$@"
fi

SCRIPT_NAME="make-emmc-sunxi.sh"
BUILD_START_TIME=$(date +%s)
: "${LOG_FILE:=build.log}"
touch "$LOG_FILE"

log_internal() {
  local LEVEL="$1"
  local MESSAGE="$2"
  local TIMESTAMP="[$(date +'%Y-%m-%d %H:%M:%S')]"
  local COLOR RESET

  case "$LEVEL" in
    INFO)    COLOR="\033[1;34m" ;;  # Blue
    WARN)    COLOR="\033[1;33m" ;;  # Yellow
    ERROR)   COLOR="\033[1;31m" ;;  # Red
    DEBUG)   COLOR="\033[1;36m" ;;  # Cyan
    PROMPT)  COLOR="\033[1;32m" ;;  # Green
    SUCCESS) COLOR="\033[1;92m" ;;  # Bright Green
    *)       COLOR="\033[0m" ;;    # Default
  esac
  RESET="\033[0m"
  local SHORT_LINE="[$LEVEL] $MESSAGE"
  local FULL_LINE="${TIMESTAMP}[$LEVEL][$SCRIPT_NAME] $MESSAGE"
  if [ -t 1 ]; then
    echo -e "${COLOR}${SHORT_LINE}${RESET}" | tee -a "$LOG_FILE"
  else
    echo "$SHORT_LINE" >> "$LOG_FILE"
  fi
  echo "$FULL_LINE" >> "$LOG_FILE"
}

info()    { log_internal INFO "$@"; }
warn()    { log_internal WARN "$@"; }
error()   { log_internal ERROR "$@"; exit 1; }
debug()   { log_internal DEBUG "$@"; }
success() { log_internal SUCCESS "$@"; }

# Prompt for output directory
OUT_DIRS=(OUT-ARM-SBC-*)
if [ ${#OUT_DIRS[@]} -eq 0 ]; then
  error "No output directories found."
fi

info "Available output directories:"
select BOARD_DIR in "${OUT_DIRS[@]}"; do
  if [ -n "$BOARD_DIR" ]; then
    OUT_DIR="$BOARD_DIR"
    break
  fi
done

dtb_file=$(find "$OUT_DIR" -name '*.dtb' | head -n1)
CHIP=$(basename "$dtb_file" | cut -d'-' -f1)
log_internal INFO "Detected chip: $CHIP"

IMAGE_NAME="$OUT_DIR/$(basename "$dtb_file" .dtb)-emmc.img"
log_internal INFO "Creating eMMC image: $IMAGE_NAME..."

dd if=/dev/zero of="$IMAGE_NAME" bs=1M count=6144

# Write bootloader
BOOTLOADER="$OUT_DIR/u-boot-sunxi-with-spl.bin"
[ -f "$BOOTLOADER" ] || error "Bootloader not found: $BOOTLOADER"
dd if="$BOOTLOADER" of="$IMAGE_NAME" bs=1024 seek=8 conv=notrunc

echo "2M,,L" | sfdisk "$IMAGE_NAME"

LOOP_DEVICE=$(losetup -f --show "$IMAGE_NAME" --partscan)
sleep 1

PART_DEV="${LOOP_DEVICE}p1"
mkfs.ext4 "$PART_DEV"
MOUNT_POINT="/mnt/${CHIP}_emmc"
mkdir -p "$MOUNT_POINT"
mount "$PART_DEV" "$MOUNT_POINT"

# Copy rootfs
ROOTFS_DIR="$OUT_DIR/rootfs"
cp -a "$ROOTFS_DIR/." "$MOUNT_POINT/"

BOOT_DIR="$MOUNT_POINT/boot"
mkdir -p "$BOOT_DIR"

cp "$OUT_DIR/Image" "$BOOT_DIR/"
cp "$dtb_file" "$BOOT_DIR/"
cp "$OUT_DIR"/config-* "$BOOT_DIR/config" 2>/dev/null || true
cp "$OUT_DIR"/System.map-* "$BOOT_DIR/System.map" 2>/dev/null || true

# Console and root device setup
CONSOLE="ttyS0"
BAUD="115200"
ROOT_DEV="/dev/mmcblk1p1"

EXTLINUX_DIR="$BOOT_DIR/extlinux"
mkdir -p "$EXTLINUX_DIR"
cat > "$EXTLINUX_DIR/extlinux.conf" <<EOF
LABEL Linux ARM-SBC
    KERNEL /boot/Image
    FDT /boot/$(basename "$dtb_file")
    APPEND console=${CONSOLE},${BAUD} root=${ROOT_DEV} rw rootwait init=/sbin/init
EOF

# Modules and firmware
if [ -d "$OUT_DIR/lib/modules" ]; then
  mkdir -p "$MOUNT_POINT/lib/modules"
  cp -a "$OUT_DIR/lib/modules/"* "$MOUNT_POINT/lib/modules/"
fi

if git clone --depth=1 https://github.com/armbian/firmware.git /tmp/armbian-firmware; then
  mkdir -p "$MOUNT_POINT/lib/firmware"
  rsync -a --delete /tmp/armbian-firmware/ "$MOUNT_POINT/lib/firmware/"
  rm -rf /tmp/armbian-firmware
fi

chown -R 1000:1000 "$MOUNT_POINT"

umount "$MOUNT_POINT"
losetup -d "$LOOP_DEVICE"

success "eMMC image created successfully: $IMAGE_NAME"

BUILD_END_TIME=$(date +%s)
DURATION=$((BUILD_END_TIME - BUILD_START_TIME))
log_internal INFO "Total build time: $((DURATION / 60))m $((DURATION % 60))s"


#!/bin/bash
BUILD_START_TIME=$(date +%s)
SCRIPT_NAME="make-sdcard.sh"

if [ "$EUID" -ne 0 ]; then
  echo "[INFO][make-sdcard.sh] Re-running script with sudo..."
  exec sudo "$0" "$@"
fi

# Function to log messages with colors
#!/bin/bash

BUILD_START_TIME=$(date +%s)
SCRIPT_NAME="make-sdcard.sh"

if [ "$EUID" -ne 0 ]; then
  echo "[INFO][${SCRIPT_NAME}] Re-running script with sudo..."
  exec sudo "$0" "$@"
fi

# --- Unified Logging System ---
: "${LOG_FILE:=build.log}"
touch "$LOG_FILE"

log_internal() {
  local LEVEL="$1"
  local MESSAGE="$2"
  local TIMESTAMP="[$(date +'%Y-%m-%d %H:%M:%S')]"
  local PREFIX COLOR RESET

  case "$LEVEL" in
    INFO)   COLOR="\033[1;34m"; PREFIX="INFO" ;;
    WARN)   COLOR="\033[1;33m"; PREFIX="WARN" ;;
    ERROR)  COLOR="\033[1;31m"; PREFIX="ERROR" ;;
    DEBUG)  COLOR="\033[1;36m"; PREFIX="DEBUG" ;;
    PROMPT) COLOR="\033[1;32m"; PREFIX="PROMPT" ;;
    *)      COLOR="\033[0m";   PREFIX="INFO" ;;
  esac
  RESET="\033[0m"

  local LOG_LINE="${TIMESTAMP}[$PREFIX][$SCRIPT_NAME] $MESSAGE"

  if [ -t 1 ]; then
    echo -e "${COLOR}${LOG_LINE}${RESET}" | tee -a "$LOG_FILE"
  else
    echo "$LOG_LINE" >> "$LOG_FILE"
  fi
}

# Aliases
info()    { log_internal INFO "$@"; }
warn()    { log_internal WARN "$@"; }
error()   { log_internal ERROR "$@"; exit 1; }
debug()   { log_internal DEBUG "$@"; }
success() { log_internal PROMPT "$@"; }
log()     { log_internal INFO "$@"; }  # legacy compatibility

# Detect available board directories
BOARD_DIRS=(OUT-ARM-SBC-*)
if [ ${#BOARD_DIRS[@]} -eq 0 ]; then
  log "ERROR" "No valid board directories found. Ensure your output directories are correctly named as OUT-ARM-SBC-<BOARD>."
  exit 1
fi

log "INFO" "Available boards:"
select BOARD_DIR in "${BOARD_DIRS[@]}"; do
  if [ -n "$BOARD_DIR" ]; then
    log "INFO" "Selected board: $BOARD_DIR"
    break
  else
    log "ERROR" "Invalid selection. Please try again."
  fi
done

# Set working directory
OUT_DIR="$BOARD_DIR"

# Determine architecture
ARCH=""
if [ -f "$OUT_DIR/Image" ]; then
  ARCH="arm64"
elif [ -f "$OUT_DIR/zImage" ]; then
  ARCH="arm32"
else
  log "ERROR" "Neither Image nor zImage found in $OUT_DIR. Cannot determine architecture."
  exit 1
fi
log "INFO" "Detected architecture: $ARCH"

# Extract chip name from device tree file
dtb_file=$(ls "$OUT_DIR"/*.dtb 2>/dev/null | head -n 1)
if [ -n "$dtb_file" ]; then
  CHIP=$(basename "$dtb_file" | cut -d'-' -f1)
  log "INFO" "Detected chip name: $CHIP"
else
  log "ERROR" "No device tree (*.dtb) file found in $OUT_DIR."
  exit 1
fi

# Determine platform type
if [[ "$CHIP" == sun* || "$CHIP" == a* ]]; then
  PLATFORM="Allwinner"
  PARTITION_START=2M
elif [[ "$CHIP" == rk* ]]; then
  PLATFORM="Rockchip"
  PARTITION_START=64M
else
  log "ERROR" "Unknown platform type. Unable to determine bootloader procedure."
  exit 1
fi
log "INFO" "Platform detected: $PLATFORM"

# Cleanup existing images
log "INFO" "Cleaning up existing images in $OUT_DIR..."
SDCARD_IMAGE="$OUT_DIR/${IMAGE_BASENAME}.img"
[ -f "$SDCARD_IMAGE" ] && rm -f "$SDCARD_IMAGE"

# Create SD card image
IMAGE_BASENAME=$(basename "$dtb_file" .dtb)
IMAGE_NAME="$OUT_DIR/${IMAGE_BASENAME}.img"
log "INFO" "Creating SD card image: $IMAGE_NAME..."
dd if=/dev/zero of="$IMAGE_NAME" bs=1M count=6144 || { log "ERROR" "Failed to create image file."; exit 1; }

# Write bootloader
log "INFO" "Writing bootloader..."
write_bootloader() {
  if [ "$PLATFORM" == "Rockchip" ]; then
    if [ -f "$OUT_DIR/idbloader.img" ] && [ -f "$OUT_DIR/u-boot.itb" ]; then
      log "INFO" "Writing idbloader and u-boot.itb to $IMAGE_NAME..."
      dd if="$OUT_DIR/idbloader.img" of="$IMAGE_NAME" bs=512 seek=64 conv=notrunc || { log "ERROR" "Failed to write idbloader.img."; exit 1; }
      dd if="$OUT_DIR/u-boot.itb" of="$IMAGE_NAME" bs=512 seek=16384 conv=notrunc || { log "ERROR" "Failed to write u-boot.itb."; exit 1; }
    elif [ -f "$OUT_DIR/u-boot-rockchip.bin" ]; then
      log "INFO" "Writing u-boot-rockchip.bin to $IMAGE_NAME..."
      dd if="$OUT_DIR/u-boot-rockchip.bin" of="$IMAGE_NAME" bs=512 seek=64 conv=notrunc || { log "ERROR" "Failed to write u-boot-rockchip.bin."; exit 1; }
    else
      log "ERROR" "No valid Rockchip bootloader found in $OUT_DIR."
      exit 1
    fi
  elif [ "$PLATFORM" == "Allwinner" ]; then
    if [ -f "$OUT_DIR/u-boot-sunxi-with-spl.bin" ]; then
      log "INFO" "Writing u-boot-sunxi-with-spl.bin to $IMAGE_NAME..."
      dd if="$OUT_DIR/u-boot-sunxi-with-spl.bin" of="$IMAGE_NAME" bs=1024 seek=8 conv=notrunc || { log "ERROR" "Failed to write u-boot-sunxi-with-spl.bin."; exit 1; }
    else
      log "ERROR" "No valid Allwinner bootloader found in $OUT_DIR."
      exit 1
    fi
  else
    log "ERROR" "Unsupported platform: $PLATFORM"
    exit 1
  fi
  sync
}

write_bootloader

# Create partition
log "INFO" "Creating partition starting at $PARTITION_START..."
echo "$PARTITION_START,,L" | sfdisk "$IMAGE_NAME" || { log "ERROR" "Failed to partition the image."; exit 1; }

# Set up loop device
LOOP_DEVICE=$(losetup -f --show "$IMAGE_NAME" --partscan) || { log "ERROR" "Failed to set up loop device."; exit 1; }
log "INFO" "Loop device created: $LOOP_DEVICE"

# Wait a moment for partition to appear
PART_DEV=""
for i in {1..10}; do
  if [ -e "${LOOP_DEVICE}p1" ]; then
    PART_DEV="${LOOP_DEVICE}p1"
    break
  elif [ -e "${LOOP_DEVICE}p01" ]; then
    PART_DEV="${LOOP_DEVICE}p01"
    break
  elif [ -e "${LOOP_DEVICE}p0p1" ]; then
    PART_DEV="${LOOP_DEVICE}p0p1"
    break
  elif [ -e "${LOOP_DEVICE}1" ]; then
    PART_DEV="${LOOP_DEVICE}1"
    break
  fi
  sleep 0.5
done

if [ -z "$PART_DEV" ] || [ ! -e "$PART_DEV" ]; then
  log "ERROR" "Partition not recognized after creation. Exiting."
  losetup -d "$LOOP_DEVICE"
  exit 1
fi

# Format partition
log "INFO" "Formatting partition with ext4..."
mkfs.ext4 "$PART_DEV" || { log "ERROR" "Failed to format partition."; losetup -d "$LOOP_DEVICE"; exit 1; }

# Mount partition
MOUNT_POINT="/mnt/${CHIP}_img"
mkdir -p "$MOUNT_POINT"
mount "$PART_DEV" "$MOUNT_POINT" || { log "ERROR" "Failed to mount partition."; losetup -d "$LOOP_DEVICE"; exit 1; }

# Detect kernel version dynamically
KERNEL_VERSION=$(basename "$OUT_DIR/config-"* 2>/dev/null | cut -d'-' -f2-)
if [ -n "$KERNEL_VERSION" ]; then
  log "INFO" "Detected kernel version: $KERNEL_VERSION"
else
  log "WARN" "Kernel version not found, skipping config and System.map copy."
fi

# Detect rootfs directory
if [ -d "$OUT_DIR/rootfs" ]; then
  ROOTFS_DIR="$OUT_DIR/rootfs"
  log "INFO" "Using prebuilt rootfs: $ROOTFS_DIR"
else
  FRESH_DIR=$(find "$OUT_DIR" -maxdepth 1 -type d -name "fresh_*" | head -n 1)
  if [ -n "$FRESH_DIR" ]; then
    ROOTFS_DIR="$FRESH_DIR"
    log "INFO" "Using detected fresh rootfs: $ROOTFS_DIR"
  else
    log "ERROR" "No rootfs directory found."
    umount "$MOUNT_POINT"; losetup -d "$LOOP_DEVICE"; exit 1
  fi
fi

# Copy root filesystem
log "INFO" "Copying root filesystem..."
cp -a "$ROOTFS_DIR/." "$MOUNT_POINT/"

# Setup boot directory
BOOT_DIR="$MOUNT_POINT/boot"
mkdir -p "$BOOT_DIR"

# Determine kernel image file
if [ -f "$OUT_DIR/Image" ]; then
  cp "$OUT_DIR/Image" "$BOOT_DIR/"
  KERNEL_FILE="Image"
elif [ -f "$OUT_DIR/zImage" ]; then
  cp "$OUT_DIR/zImage" "$BOOT_DIR/"
  KERNEL_FILE="zImage"
else
  log "ERROR" "No kernel image found (Image or zImage)."
  umount "$MOUNT_POINT"; losetup -d "$LOOP_DEVICE"; exit 1
fi

# Copy DTB(s)
[ -n "$(ls "$OUT_DIR"/*.dtb 2>/dev/null)" ] && cp "$OUT_DIR"/*.dtb "$BOOT_DIR/"

# Copy config and System.map
[ -f "$OUT_DIR/config-$KERNEL_VERSION" ] && cp "$OUT_DIR/config-$KERNEL_VERSION" "$BOOT_DIR/config"
[ -f "$OUT_DIR/System.map-$KERNEL_VERSION" ] && cp "$OUT_DIR/System.map-$KERNEL_VERSION" "$BOOT_DIR/System.map"

# Generate extlinux.conf dynamically
log "INFO" "Creating extlinux.conf..."
EXTLINUX_DIR="$BOOT_DIR/extlinux"
mkdir -p "$EXTLINUX_DIR"

case "$CHIP" in
  rk3588|rk3568|rk3399)
    CONSOLE="ttyS2"
    BAUD="1500000"
    ;;
  rk3576)
    CONSOLE="ttyS0"
    BAUD="1500000"
    ;;
  rk3288|rk3128)
    CONSOLE="ttyS2"
    BAUD="115200"
    ;;
  *)
    CONSOLE="ttyS2"
    BAUD="1500000"
    ;;
esac

# Generate extlinux.conf
cat > "$EXTLINUX_DIR/extlinux.conf" <<EOF
LABEL Linux ARB-SBC
    KERNEL /boot/$KERNEL_FILE
    FDT /boot/$(basename "$dtb_file")
    APPEND console=$CONSOLE,$BAUD root=/dev/mmcblk1p1 rw rootwait init=/sbin/init
EOF
log "INFO" "extlinux.conf created at $EXTLINUX_DIR"

# Copy kernel modules if available
if [ -d "$OUT_DIR/lib/modules" ]; then
  log "INFO" "Copying kernel modules..."
  mkdir -p "$MOUNT_POINT/lib/modules"
  cp -a "$OUT_DIR/lib/modules/"* "$MOUNT_POINT/lib/modules/"
fi

# Clone and copy Armbian firmware
log "INFO" "Cloning Armbian firmware repository..."
if git clone --depth=1 https://github.com/armbian/firmware.git /tmp/armbian-firmware; then
  log "INFO" "Copying firmware into rootfs..."
  mkdir -p "$MOUNT_POINT/lib/firmware"
  rsync -a --delete /tmp/armbian-firmware/ "$MOUNT_POINT/lib/firmware/"
  rm -rf /tmp/armbian-firmware
else
  log "WARN" "Failed to clone Armbian firmware repository. Skipping firmware copy."
fi

# Fix ownership to UID 1000 inside the SD image
log "INFO" "Fixing ownership inside rootfs (UID 1000)..."
chown -R 1000:1000 "$MOUNT_POINT"

# Unmount and finalize
umount "$MOUNT_POINT"
losetup -d "$LOOP_DEVICE"
log "INFO" "SD card image creation completed successfully."

BUILD_END_TIME=$(date +%s)
BUILD_DURATION=$((BUILD_END_TIME - BUILD_START_TIME))
minutes=$((BUILD_DURATION / 60))
seconds=$((BUILD_DURATION % 60))

success "SD card image created successfully in ${minutes}m ${seconds}s"
info "Exiting script: $SCRIPT_NAME"
exit 0


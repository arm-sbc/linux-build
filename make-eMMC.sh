#!/bin/bash
set -e

SCRIPT_NAME="make-eMMC.sh"
# Function to log messages with colors
BUILD_START_TIME=$(date +%s)
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
log()     { log_internal INFO "$@"; }  # Legacy alias

pause() {
log ERROR "Press any key to quit."
read -n1 -s
  exit 1
}

#--- Prompt for OUT_DIR if multiple exist ---#
if [ -z "$OUT_DIR" ]; then
  OUT_DIRS=($(find . -maxdepth 1 -type d -name 'OUT-ARM-SBC-*' | sed 's|^\./||'))

  if [ ${#OUT_DIRS[@]} -eq 0 ]; then
log ERROR "No OUT-ARM-SBC-* directory found.";pause
  elif [ ${#OUT_DIRS[@]} -eq 1 ]; then
    OUT_DIR="${OUT_DIRS[0]}"
log INFO "Auto-selected OUT_DIR: $OUT_DIR"
else
    echo "[PROMPT] Multiple OUT directories found. Please choose:"
    select dir in "${OUT_DIRS[@]}"; do
      if [ -n "$dir" ]; then
        OUT_DIR="$dir"
        break
      fi
    done
  fi
fi

#--- Derive BOARD from OUT_DIR ---#
if [ -z "$BOARD" ]; then
  BOARD=$(echo "$OUT_DIR" | sed 's/^OUT-ARM-SBC-//')
log INFO "Auto-detected BOARD: $BOARD"
fi

#--- Derive CHIP from DTB ---#
if [ -z "$CHIP" ]; then
  DTB_PATH=$(find "$OUT_DIR" -name '*.dtb' | head -n1)
  if [ -n "$DTB_PATH" ]; then
    CHIP=$(basename "$DTB_PATH" | cut -d'-' -f1)
log INFO "Detected CHIP from DTB: $CHIP"
else
log ERROR "Could not auto-detect CHIP. Please set it manually."pause
  fi
fi

#--- Paths and Tools ---#
#OUT_DIR="OUT-$BOARD"
IMAGE_DIR="$OUT_DIR"
OUT_UPDATE_IMG="$OUT_DIR/update-emmc-$BOARD.img"
RAW_IMG="$OUT_DIR/update-emmc.raw.img"

#--- Auto-detect CHIP from DTB in OUT_DIR ---#
if [ -z "$CHIP" ]; then
  DTB_PATH=$(find "$OUT_DIR" -name '*.dtb' | head -n1)
  if [ -n "$DTB_PATH" ]; then
    CHIP=$(basename "$DTB_PATH" | cut -d'-' -f1)
log INFO "Detected CHIP from DTB: $CHIP"
else
log ERROR "Could not auto-detect CHIP. Please set it manually."pause
  fi
fi

PARAMETER_FILE="rk-tools/${CHIP}-parameter.txt"
PACKAGE_FILE="rk-tools/${CHIP}-package-file"
AFPTOOL="rk-tools/afptool"
RKIMAGEMAKER="rk-tools/rkImageMaker"
RKBOOT_INI="rkbin/RKBOOT/${CHIP^^}MINIALL.ini"
BOOT_MERGER="rkbin/tools/boot_merger"

#--- Generate Loader if not found ---#
LOADER_BIN="$OUT_DIR/${CHIP}_loader.bin"

if [ ! -f "$LOADER_BIN" ]; then
log INFO "Loader not found. Attempting to generate using boot_merger..."
[ -x "$BOOT_MERGER" ] || chmod +x "$BOOT_MERGER"
  [ -f "$RKBOOT_INI" ] || { echo "[ERROR] Missing RKBOOT ini file: $RKBOOT_INI"; pause; }

	pushd rkbin > /dev/null
	./tools/boot_merger "RKBOOT/${CHIP^^}MINIALL.ini" || pause
	echo "[DEBUG] Contents of rkbin after boot_merger:"
	ls -lh *.bin bin/ || true
	popd > /dev/null

  # Determine CHIP_FAMILY for special cases like rk3566/rk3568
  case "$CHIP" in
    rk3566|rk3568)
      CHIP_FAMILY="rk356x"
      ;;
    *)
      CHIP_FAMILY="$CHIP"
      ;;
  esac

  # Unified loader detection based on CHIP and CHIP_FAMILY
  GENERATED_LOADER=$(find rkbin rkbin/bin -maxdepth 1 -type f \( \
    -iname "${CHIP}_spl_loader_*.bin" -o \
    -iname "${CHIP}_loader_*.bin" -o \
    -iname "${CHIP_FAMILY}_spl_loader_*.bin" -o \
    -iname "${CHIP_FAMILY}_loader_*.bin" \
  \) | sort | tail -n1)

  echo "[DEBUG] Using loader: $GENERATED_LOADER"

  [ -f "$GENERATED_LOADER" ] || { echo "[ERROR] Failed to generate loader."; pause; }

  cp "$GENERATED_LOADER" "$LOADER_BIN"
  cp "$GENERATED_LOADER" "$OUT_DIR/$(basename "$GENERATED_LOADER")"  # For afptool compatibility
log INFO "Loader generated and copied to: $LOADER_BIN"
fi

#--- Validate Inputs ---#
log INFO "Validating required files..."
[ -f "$PARAMETER_FILE" ] || { echo "[ERROR] parameter file not found: $PARAMETER_FILE"; pause; }
[ -f "$PACKAGE_FILE" ] || { echo "[ERROR] package file not found: $PACKAGE_FILE"; pause; }
[ -f "$LOADER_BIN" ] || { echo "[ERROR] Loader binary not found at $LOADER_BIN"; pause; }

#--- Prepare boot directory with kernel, dtb, config, System.map, extlinux.conf ---#
log INFO "Preparing boot directory..."
BOOT_DIR="$OUT_DIR/boot"
mkdir -p "$BOOT_DIR"

cp "$OUT_DIR/Image" "$BOOT_DIR/" || pause
DTB_FILE=$(find "$OUT_DIR" -name "*.dtb" | grep -i "$CHIP" | head -n1)
[ "$DTB_FILE" != "$BOOT_DIR/$(basename "$DTB_FILE")" ] && cp "$DTB_FILE" "$BOOT_DIR/" || 
echo "[INFO] Skipping DTB copy to avoid duplication."
cp "$OUT_DIR"/config-* "$BOOT_DIR/" || true
cp "$OUT_DIR"/System.map-* "$BOOT_DIR/" || true

# Generate extlinux.conf
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

cat > "$EXTLINUX_DIR/extlinux.conf" <<EOF
LABEL Linux ARB-SBC
    KERNEL /Image
    FDT /$(basename "$DTB_FILE")
    APPEND console=$CONSOLE,$BAUD root=/dev/mmcblk0p4 rw rootwait init=/sbin/init
EOF

#--- Generate ext2-based boot.img ---#
log INFO "Creating ext2-based boot.img..."
BOOT_IMG="$OUT_DIR/boot_${CHIP}.img"

BLOCK_SIZE=4096
INODES=8192

# Calculate used size in KB and apply 25% safety margin
USED_KB=$(du -s --block-size=1024 "$BOOT_DIR" | cut -f1)
PADDING_KB=$(( USED_KB / 4 ))
TOTAL_KB=$(( USED_KB + PADDING_KB ))

# Enforce a minimum size of 32MB
MIN_KB=$(( 32 * 1024 ))
[ "$TOTAL_KB" -lt "$MIN_KB" ] && TOTAL_KB="$MIN_KB"

BLOCKS=$(( TOTAL_KB * 1024 / BLOCK_SIZE ))

genext2fs -b "$BLOCKS" -B "$BLOCK_SIZE" -d "$BOOT_DIR" -i "$INODES" -U "$BOOT_IMG" || pause

#--- Create ext4-based rootfs.img from rootfs directory ---#
log INFO "Creating ext4 rootfs.img from $OUT_DIR/rootfs..."
ROOTFS_DIR="$OUT_DIR/rootfs"
ROOTFS_IMG="$OUT_DIR/rootfs.img"
MNT_ROOTFS="$OUT_DIR/mnt_rootfs"

# Fixed size: 5 GB = 5 * 1024 * 1024 KB = 5242880 KB
FIXED_KB=$((5 * 1024 * 1024))
log INFO "Creating fixed size 5GB rootfs.img ($(( FIXED_KB / 1024 )) MB).."
dd if=/dev/zero of="$ROOTFS_IMG" bs=1K count=$FIXED_KB
mkfs.ext4 -F "$ROOTFS_IMG"

mkdir -p "$MNT_ROOTFS"
sudo mount "$ROOTFS_IMG" "$MNT_ROOTFS"
log INFO "Copying files to rootfs.img..."
sudo rsync -aAX --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*"} "$ROOTFS_DIR/" "$MNT_ROOTFS/"
debug "Contents of rootfs: $(ls -1 "$ROOTFS_DIR" | wc -l) files/folders"

# Copy kernel modules if available
if [ -d "$OUT_DIR/lib/modules" ]; then
log INFO "Copying kernel modules..."
sudo mkdir -p "$MNT_ROOTFS/lib/modules"
  sudo cp -a "$OUT_DIR/lib/modules/"* "$MNT_ROOTFS/lib/modules/"
fi

log INFO "Cloning Armbian firmware repository..."
if git clone --depth=1 https://github.com/armbian/firmware.git /tmp/armbian-firmware; then
  log INFO "Copying firmware into rootfs..."
  sudo mkdir -p "$MNT_ROOTFS/lib/firmware"
  sudo rsync -a --delete /tmp/armbian-firmware/ "$MNT_ROOTFS/lib/firmware/"
  rm -rf /tmp/armbian-firmware
else
  log WARN "Failed to clone Armbian firmware repository. Skipping firmware copy."
fi

sync
sudo umount "$MNT_ROOTFS"
rmdir "$MNT_ROOTFS"

log SUCCESS "rootfs.img created at: $ROOTFS_IMG"

#--- Generate raw image with afptool ---#
log INFO "Copying parameter.txt into OUT_DIR..."
cp "$PARAMETER_FILE" "$OUT_DIR/parameter.txt" || { echo "[ERROR] Failed to copy parameter.txt to $OUT_DIR"; pause; }
log INFO "Packing raw image using afptool..."
$AFPTOOL -pack "$OUT_DIR" "$RAW_IMG" "$PACKAGE_FILE" || pause

#--- Extract RK Tag from MiniLoader for proper RKFW header ---#
TAG="RK$(hexdump -s 21 -n 4 -e '4 "%c"' "$LOADER_BIN" | rev)"
log INFO "Using RK Tag: $TAG"

#--- Generate final update.img using rkImageMaker ---#
log INFO "Creating final update.img using rkImageMaker..."
$RKIMAGEMAKER -$TAG "$LOADER_BIN" "$RAW_IMG" "$OUT_UPDATE_IMG" -os_type:linux || pause

#--- Final Check ---#
[ -f "$OUT_UPDATE_IMG" ] && success "update-eMMC.img created successfully: $OUT_UPDATE_IMG" || pause

if [ -n "$BUILD_START_TIME" ]; then
  BUILD_END_TIME=$(date +%s)
  BUILD_DURATION=$((BUILD_END_TIME - BUILD_START_TIME))
  minutes=$((BUILD_DURATION / 60))
  seconds=$((BUILD_DURATION % 60))
log INFO "Total build time: ${minutes}m ${seconds}s"
else

log WARN "BUILD_START_TIME not set. Cannot show elapsed time."
fi

exit 0


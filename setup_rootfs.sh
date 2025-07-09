#!/bin/bash
set -e

# Map ROOTFS_VERSION to VERSION if not already set
if [ -z "$VERSION" ] && [ -n "$ROOTFS_VERSION" ]; then
  VERSION="$ROOTFS_VERSION"
fi

SCRIPT_NAME=$(basename "$0")
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
    *)       COLOR="\033[0m"   ;;  # Default
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

# Logging aliases
info()    { log_internal INFO "$@"; }
warn()    { log_internal WARN "$@"; }
error()   { log_internal ERROR "$@"; exit 1; }
debug()   { log_internal DEBUG "$@"; }
success() { log_internal SUCCESS "$@"; }
prompt()  { log_internal PROMPT "$@"; }
log()     { log_internal INFO "$@"; }  # legacy

# --- Validate required variables ---
if [ -z "$BOARD" ] || [ -z "$ARCH" ] || [ -z "$VERSION" ]; then
  error "Required variables BOARD, ARCH, or VERSION are missing. Exiting."
fi

# --- Export fallback defaults for rootfs if not already set ---
: "${ROOTFS_SOURCE:=prebuilt}" && export ROOTFS_SOURCE
: "${ROOTFS_DISTRO:=ubuntu}" && export ROOTFS_DISTRO
: "${ROOTFS_VERSION:=$VERSION}" && export ROOTFS_VERSION

# --- Validate rootfs variables ---
if [ -z "$ROOTFS_SOURCE" ] || [ -z "$ROOTFS_DISTRO" ] || [ -z "$ROOTFS_VERSION" ]; then
  error "Missing one or more required variables: ROOTFS_SOURCE, ROOTFS_DISTRO, ROOTFS_VERSION."
fi

# Optional debug output
debug "BOARD=$BOARD"
debug "ARCH=$ARCH"
debug "VERSION=$VERSION"
debug "ROOTFS_SOURCE=$ROOTFS_SOURCE"
debug "ROOTFS_DISTRO=$ROOTFS_DISTRO"
debug "ROOTFS_VERSION=$ROOTFS_VERSION"
debug "OUTPUT_DIR=${OUTPUT_DIR:-undefined}"

info "Starting root filesystem creation for Board: $BOARD, Architecture: $ARCH, Version: $VERSION"

# Check for sudo access
info "Checking for sudo access..."
if ! sudo -v; then
    error "This script requires sudo privileges. Please run as a user with sudo access."
    exit 1
fi
info "Sudo access verified."

prepare_rootfs() {
  ROOTFS_DIR="$OUTPUT_DIR/rootfs"
  IMAGES_DIR="$OUTPUT_DIR/images"
  BASE_URL="https://images.linuxcontainers.org/images"

  case "$ARCH" in
    "arm")   ARCH_URL="armhf" ;;
    "arm64") ARCH_URL="arm64" ;;
    *) error "Unsupported architecture: $ARCH" ;;
  esac

  case "$ROOTFS_DISTRO" in
    "ubuntu"|"debian") ;;
    *) error "Invalid ROOTFS_DISTRO: $ROOTFS_DISTRO" ;;
  esac

  ROOTFS_URL="$BASE_URL/$ROOTFS_DISTRO/$ROOTFS_VERSION/$ARCH_URL/default/"
  info "Fetching rootfs from: $ROOTFS_URL"

  wget -q -O /tmp/rootfs_listing.html "$ROOTFS_URL" || error "Failed to fetch listing."
  LATEST_DATE=$(grep -oP '\d{8}_\d{2}:\d{2}' /tmp/rootfs_listing.html | sort | tail -n1)
  if [ -z "$LATEST_DATE" ]; then
    error "Could not determine latest rootfs."
  fi

  IMAGE_URL="${ROOTFS_URL}${LATEST_DATE}/rootfs.tar.xz"
  mkdir -p "$IMAGES_DIR"
  wget -q -O "$IMAGES_DIR/rootfs.tar.xz" "$IMAGE_URL" || error "Download failed."

  sudo rm -rf "$ROOTFS_DIR"
  mkdir -p "$ROOTFS_DIR"
  
  ls -lh "$IMAGES_DIR/rootfs.tar.xz"
  file "$IMAGES_DIR/rootfs.tar.xz"
  
  tar --numeric-owner -xf "$IMAGES_DIR/rootfs.tar.xz" -C "$ROOTFS_DIR" || error "Extraction failed."

  info "Root filesystem extracted to: $ROOTFS_DIR"
  
  info "Fixing sudo ownership and permissions..."
  sudo chown root:root "$ROOTFS_DIR/usr/bin/sudo" 2>/dev/null || true
  sudo chmod 4755 "$ROOTFS_DIR/usr/bin/sudo" 2>/dev/null || true
  sudo chown root:root "$ROOTFS_DIR/etc/sudo.conf" 2>/dev/null || true
  sudo chown root:root "$ROOTFS_DIR/etc/sudoers" 2>/dev/null || true
  sudo chmod 440 "$ROOTFS_DIR/etc/sudoers" 2>/dev/null || true
  sudo chown -R root:root "$ROOTFS_DIR/etc/sudoers.d" 2>/dev/null || true

  info "Sudo permissions and ownership fixed for rootfs."

  if [ "$ARCH" = "arm64" ]; then
    QEMU_BIN="/usr/bin/qemu-aarch64-static"
  elif [ "$ARCH" = "arm" ]; then
    QEMU_BIN="/usr/bin/qemu-arm-static"
  else
    error "Unsupported ARCH for chroot password setup"
  fi

  if [ ! -f "$QEMU_BIN" ]; then
    error "Missing QEMU binary: $QEMU_BIN"
  fi

  sudo cp "$QEMU_BIN" "$ROOTFS_DIR/usr/bin/"

  info "Chrooting to set root and ubuntu passwords..."
  sudo chroot "$ROOTFS_DIR" /bin/bash -c "\
    echo 'Please set password for root:' && \
    passwd root && \
    if id ubuntu >/dev/null 2>&1; then \
      echo 'Please set password for user ubuntu:' && \
      passwd ubuntu; \
    fi"
    
    
  prompt "Do you want to install desktop environment and utilities inside the rootfs? [y/N]"
  read -r DESKTOP_YN
  if [[ "$DESKTOP_YN" =~ ^[Yy]$ ]]; then
    ./postinstall-desktop.sh "$ROOTFS_DIR" "$ARCH" "$QEMU_BIN" "$ROOTFS_VERSION"
  else
    info "Skipping desktop installation."
  fi
}

create_fresh_rootfs() {
  FRESH_DIR="$OUTPUT_DIR/fresh_$ROOTFS_VERSION"
  info "Creating fresh rootfs: $FRESH_DIR"

  sudo rm -rf "$FRESH_DIR"
  mkdir -p "$FRESH_DIR"

  [[ "$ARCH" == "arm" ]] && ARCH_DEB=armhf && QEMU="/usr/bin/qemu-arm-static"
  [[ "$ARCH" == "arm64" ]] && ARCH_DEB=arm64 && QEMU="/usr/bin/qemu-aarch64-static"

  [[ -z "$ARCH_DEB" ]] && error "Unsupported ARCH for debootstrap"

  sudo apt-get install -y debootstrap qemu-user-static
  sudo debootstrap --arch=$ARCH_DEB --foreign "$ROOTFS_VERSION" "$FRESH_DIR"
  sudo cp "$QEMU" "$FRESH_DIR/usr/bin/"

  sudo chroot "$FRESH_DIR" /debootstrap/debootstrap --second-stage

  case "$ROOTFS_DISTRO" in
    ubuntu)
      cat <<EOF | sudo tee "$FRESH_DIR/etc/apt/sources.list" > /dev/null
deb http://ports.ubuntu.com/ubuntu-ports $ROOTFS_VERSION main universe multiverse restricted
deb http://ports.ubuntu.com/ubuntu-ports $ROOTFS_VERSION-updates main universe multiverse restricted
deb http://ports.ubuntu.com/ubuntu-ports $ROOTFS_VERSION-security main universe multiverse restricted
EOF
      ;;
    debian)
      cat <<EOF | sudo tee "$FRESH_DIR/etc/apt/sources.list" > /dev/null
deb http://deb.debian.org/debian $ROOTFS_VERSION main contrib
deb http://deb.debian.org/debian $ROOTFS_VERSION-updates main contrib
deb http://security.debian.org/ $ROOTFS_VERSION-security main contrib
EOF
      ;;
    *)
      warn "Unknown distro. Skipping APT setup."
      ;;
  esac

  info "Setting root password in fresh rootfs..."
  sudo chroot "$FRESH_DIR" /bin/bash -c "\
    echo 'Please set password for root:' && \
    passwd root"
    
  prompt "Do you want to install desktop environment and utilities inside the rootfs? [y/N]"
  read -r DESKTOP_YN
  if [[ "$DESKTOP_YN" =~ ^[Yy]$ ]]; then
    ./postinstall-desktop.sh "$FRESH_DIR" "$ARCH" "$QEMU" "$ROOTFS_VERSION"
  else
    info "Skipping desktop installation."
  fi

  info "Fresh rootfs prepared in: $FRESH_DIR"
}

if [ "$ROOTFS_SOURCE" = "prebuilt" ]; then
  info "ROOTFS_SOURCE is 'prebuilt'. Proceeding with downloading rootfs..."
  prepare_rootfs
elif [ "$ROOTFS_SOURCE" = "fresh" ]; then
  info "ROOTFS_SOURCE is 'fresh'. Proceeding with creating rootfs from debootstrap..."
  create_fresh_rootfs
else
  error "Invalid ROOTFS_SOURCE: '$ROOTFS_SOURCE'. Must be 'prebuilt' or 'fresh'."
  exit 1
fi

# --- Prompt to create Rockchip images ---#
echo
prompt "Do you want to create Rockchip images now?"
echo "1. Create SD card image"
echo "2. Create eMMC image"
echo "3. Create both"
echo "4. Skip"
prompt "Enter your choice (1/2/3/4):"
read -r IMAGE_OPTION

case $IMAGE_OPTION in
    1)
        ./make-sdcard.sh || error "Failed to create SD card image."
        ;;
    2)
        ./make-eMMC.sh || error "Failed to create eMMC image."
        ;;
    3)
        ./make-sdcard.sh || error "Failed to create SD card image."
        ./make-eMMC.sh || error "Failed to create eMMC image."
        ;;
    4)
        info "Skipping image creation."
        ;;
    *)
        warning "Invalid choice. Skipping image creation."
        ;;
esac

# --- Build Duration Summary ---
if [ -n "$BUILD_START_TIME" ]; then
  BUILD_END_TIME=$(date +%s)
  BUILD_DURATION=$((BUILD_END_TIME - BUILD_START_TIME))
  minutes=$((BUILD_DURATION / 60))
  seconds=$((BUILD_DURATION % 60))
  echo -e "\033[1;34m[INFO]\033[0m Total build time: ${minutes}m ${seconds}s"
else
  echo -e "\033[1;33m[WARN]\033[0m BUILD_START_TIME not set. Cannot display build duration."
fi

info "Rootfs creation and image options completed."

# --- Script Footer ---
BUILD_END_TIME=$(date +%s)
BUILD_DURATION=$((BUILD_END_TIME - BUILD_START_TIME))
minutes=$((BUILD_DURATION / 60))
seconds=$((BUILD_DURATION % 60))

success "RootFS setup completed in ${minutes}m ${seconds}s"
info "Exiting script: $SCRIPT_NAME"
exit 0


#!/bin/bash
set -e

SCRIPT_NAME="prepare_sources.sh"
: "${LOG_FILE:=build.log}"
touch "$LOG_FILE"

log() {
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
    SUCCESS) COLOR="\033[1;92m" ;;  # Bright green
    *)       COLOR="\033[0m"   ;;  # Default
  esac
  RESET="\033[0m"

  local LOG_LINE="${TIMESTAMP}[$LEVEL][$SCRIPT_NAME] $MESSAGE"
  local SHORT_LINE="[$LEVEL] $MESSAGE"

  if [ -t 1 ]; then
    echo -e "${COLOR}${SHORT_LINE}${RESET}"
  else
    echo "$SHORT_LINE"
  fi

  echo "$LOG_LINE" >> "$LOG_FILE"
}

install_dependencies() {
  log INFO "Checking and installing required system dependencies..."

  REQUIRED_PACKAGES=(
    "build-essential" "gcc" "gcc-arm-none-eabi" "make" "swig" "gcc-arm-linux-gnueabihf"
    "libssl-dev" "curl" "bison" "flex" "git" "wget" "bc" "python3" "libncurses-dev"
    "libgnutls28-dev" "uuid-dev" "python3-pip" "device-tree-compiler" "genext2fs"
    "gcc-aarch64-linux-gnu" "g++-aarch64-linux-gnu" "debootstrap" "qemu-user"
    "qemu-user-static" "binfmt-support" "picocom" "python3-pyelftools"
  )
  MISSING_PACKAGES=()

  for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg -l | grep -qw "$pkg"; then
      MISSING_PACKAGES+=("$pkg")
    fi
  done

  if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    log INFO "Installing missing packages: ${MISSING_PACKAGES[*]}"
    sudo apt update
    sudo apt install -y "${MISSING_PACKAGES[@]}" || {
      log INFO "[ERROR] Failed to install some packages. Exiting."
      exit 1
    }
    log INFO "All required system packages have been installed."
  else
    log INFO "All required system dependencies are already installed."
  fi

  # Optionally ensure pipx is installed if you use it elsewhere
  if ! command -v pipx >/dev/null 2>&1; then
    log INFO "Installing pipx (optional)"
    sudo apt install -y pipx && pipx ensurepath
  fi
}

# Function to clean and prepare build directories
clean_build_directories() {
  log INFO "Cleaning previous build directories..."

  # Remove u-boot directory
  [ -d "u-boot" ] && rm -rf "u-boot"

  # Find and remove any directory that starts with "linux-"
  for linux_dir in linux-*; do
    if [ -d "$linux_dir" ]; then
      log INFO "Removing directory: $linux_dir"
      sudo rm -rf "$linux_dir"
    fi
  done

  log INFO "Build directories cleaned."
}
prepare_output_directory() {
  if [[ -z "$BOARD" ]]; then
    log ERROR "BOARD variable is not set. Cannot create output directory."
    exit 1
  fi

  OUTPUT_DIR="$(pwd)/OUT-${BOARD}"  # Use absolute path
  export OUTPUT_DIR

  log INFO "Preparing output directory: $OUTPUT_DIR..."

  if [[ -d "$OUTPUT_DIR" ]]; then
    log INFO "Cleaning output directory contents..."
    sudo rm -rf "$OUTPUT_DIR"/* || { log ERROR "Failed to clean $OUTPUT_DIR."; exit 1; }
  else
    log INFO "Creating output directory: $OUTPUT_DIR..."
    mkdir -p "$OUTPUT_DIR" || { log ERROR "Failed to create $OUTPUT_DIR."; exit 1; }
  fi

  log SUCCESS "Output directory is ready."
}

download_uboot_sources() {
  log INFO "Downloading U-Boot, ATF, OP-TEE, and rkbin if needed..."

  if [ ! -d u-boot ]; then
    git clone https://github.com/u-boot/u-boot.git && \
      (cd u-boot && git checkout master)
  else
    log INFO "u-boot directory already exists. Skipping clone."
  fi

  if [ ! -d rkbin ]; then
    git clone https://github.com/rockchip-linux/rkbin.git
  else
    log INFO "rkbin directory already exists. Skipping clone."
  fi

  if [ ! -d trusted-firmware-a ]; then
    git clone https://git.trustedfirmware.org/TF-A/trusted-firmware-a.git
  else
    (cd trusted-firmware-a && git pull origin master || true)
  fi

  if [ ! -d optee_os ]; then
    git clone https://github.com/OP-TEE/optee_os.git
  fi
}

download_kernel_source() {
  [ -z "$KERNEL_VERSION" ] && error "KERNEL_VERSION is not set. Export it before running this script."
  KERNEL_TAR="linux-${KERNEL_VERSION}.tar.xz"
  KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_VERSION%%.*}.x/${KERNEL_TAR}"

  if [ ! -f "$KERNEL_TAR" ]; then
    log INFO "Downloading Linux kernel source: $KERNEL_TAR"
    wget "$KERNEL_URL" -O "$KERNEL_TAR"
  else
    log INFO "$KERNEL_TAR already exists. Skipping download."
  fi

  if [ ! -d "linux-${KERNEL_VERSION}" ]; then
    log INFO "Extracting kernel source..."
    tar -xf "$KERNEL_TAR"
  else
    log INFO "linux-${KERNEL_VERSION} already extracted. Skipping."
  fi
}

main() {
  log INFO "Starting source preparation..."
  install_dependencies
  clean_build_directories
  prepare_output_directory
  download_uboot_sources
  download_kernel_source
  log INFO "Source preparation completed successfully."
}

main "$@"


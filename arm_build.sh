#!/bin/bash
set -e

SCRIPT_NAME="set_env.sh"
BUILD_START_TIME=$(date +%s)
: "${LOG_FILE:=build.log}"
touch "$LOG_FILE"

read LINES COLUMNS < <(stty size)
DIALOG_HEIGHT=$((LINES > 25 ? 20 : (LINES - 5 < 10 ? 10 : LINES - 5)))
DIALOG_WIDTH=$((COLUMNS > 90 ? 70 : (COLUMNS - 10 < 40 ? 40 : COLUMNS - 10)))

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
  echo -e "${COLOR}${TIMESTAMP}[$PREFIX][$SCRIPT_NAME] $MESSAGE${RESET}"
  echo "${TIMESTAMP}[$PREFIX][$SCRIPT_NAME] $MESSAGE" >> "$LOG_FILE"
}

save_config() {
  cat > .config <<EOF
CHIP_FAMILY=$CHIP_FAMILY
BOARD=$BOARD
KERNEL_VERSION=$KERNEL_VERSION
ROOTFS_METHOD=$ROOTFS_METHOD
BUILD_OPTION=$BUILD_OPTION
ROOTFS_DISTRO=$ROOTFS_DISTRO
ROOTFS_VERSION=$ROOTFS_VERSION
EOF
  log_internal INFO "Configuration saved to .config"
}

load_board_config() {
  local CONFIG_FILE="boards/$CHIP_FAMILY/$BOARD/board_config.sh"
  if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    export CHIP ARCH CROSS_COMPILE UBOOT_DEFCONFIG KERNEL_DEFCONFIG DEVICE_TREE
    log_internal INFO "Loaded board config from $CONFIG_FILE"
  else
    log_internal ERROR "Missing board_config.sh for $BOARD"
    exit 1
  fi
}

check_dialog_installed() {
  if ! command -v dialog &>/dev/null; then
    log_internal ERROR "dialog not found. Please install with: sudo apt install dialog"
    exit 1
  fi
}

select_family() {
  exec 3>&1
  CHIP_FAMILY=$(dialog --menu "Select SoC Family:" $DIALOG_HEIGHT $DIALOG_WIDTH 5 \
    rockchip "Rockchip SoCs" \
    sunxi "Allwinner SoCs" \
    3>&1 1>&2 2>&3)
  clear
  log_internal INFO "Selected SoC family: $CHIP_FAMILY"
}

select_board() {
  local BOARD_DIR="boards/$CHIP_FAMILY"
  [[ -d "$BOARD_DIR" ]] || { log_internal ERROR "Missing directory: $BOARD_DIR"; exit 1; }

  local OPTIONS=()
  for board in "$BOARD_DIR"/*; do
    [ -d "$board" ] || continue
    OPTIONS+=("$(basename "$board")" "")
  done

  exec 3>&1
  BOARD=$(dialog --menu "Choose Board:" $DIALOG_HEIGHT $DIALOG_WIDTH 10 "${OPTIONS[@]}" 3>&1 1>&2 2>&3)
  clear
  log_internal INFO "Selected board: $BOARD"
}

select_build_option() {
  exec 3>&1
  BUILD_OPTION=$(dialog --menu "Build Option:" $DIALOG_HEIGHT $DIALOG_WIDTH 7 \
    uboot "U-Boot only" \
    kernel "Kernel only" \
    rootfs "Rootfs only" \
    uboot+kernel "U-Boot + Kernel only" \
    all "All (uboot+kernel+rootfs)" \
    go_back "← Go back to board selection" \
    3>&1 1>&2 2>&3)

  clear
  log_internal INFO "Selected build option: $BUILD_OPTION"
}

select_kernel_version() {
  if [[ "$CHIP" == a* ]]; then
    log_internal INFO "Allwinner board detected. Automatically selecting latest stable kernel..."
    KERNEL_VERSION=$(curl -s https://www.kernel.org/ | grep -oP 'linux-\K[0-9]+\.[0-9]+\.[0-9]+(?=\.tar\.xz)' | grep -v rc | head -n 1)

    if [ -z "$KERNEL_VERSION" ]; then
      log_internal ERROR "Failed to fetch latest stable kernel for Allwinner."
      exit 1
    fi

    log_internal INFO "Selected kernel version: $KERNEL_VERSION"
  else
    log_internal INFO "Fetching latest stable kernel version from kernel.org..."
    STABLE=$(curl -s https://www.kernel.org/ | grep -oP 'linux-\K[0-9]+\.[0-9]+\.[0-9]+(?=\.tar\.xz)' | grep -v rc | head -n 1)

    if [[ -z "$STABLE" ]]; then
      log_internal ERROR "Failed to fetch kernel version from kernel.org"
      exit 1
    fi

    exec 3>&1
    KERNEL_OPTION=$(dialog --menu "Select kernel version:" $DIALOG_HEIGHT $DIALOG_WIDTH 5 \
      "$STABLE" "Latest Stable (Recommended)" \
      custom "Enter manually" \
      3>&1 1>&2 2>&3)

    if [ "$KERNEL_OPTION" = "custom" ]; then
      KERNEL_VERSION=$(dialog --inputbox "Enter custom kernel version (e.g., 6.9.2):" 8 50 3>&1 1>&2 2>&3)
    else
      KERNEL_VERSION="$KERNEL_OPTION"
    fi

    if ! [[ "$KERNEL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      log_internal ERROR "Invalid kernel version format: $KERNEL_VERSION"
      exit 1
    fi

    clear
    log_internal INFO "Selected kernel version: $KERNEL_VERSION"
  fi
  export KERNEL_VERSION
}

select_rootfs_method() {
  exec 3>&1
  ROOTFS_METHOD=$(dialog --menu "Rootfs Source:" $DIALOG_HEIGHT $DIALOG_WIDTH 5 \
    prebuilt "Download from LinuxContainers" \
    debootstrap "Use debootstrap to create" \
    3>&1 1>&2 2>&3)
  clear
  log_internal INFO "Selected rootfs method: $ROOTFS_METHOD"

  if [[ "$ROOTFS_METHOD" =~ ^(prebuilt|debootstrap)$ ]]; then
    exec 3>&1
    ROOTFS_DISTRO=$(dialog --menu "Choose Rootfs Distribution:" $DIALOG_HEIGHT $DIALOG_WIDTH 4 \
      ubuntu "Ubuntu" \
      debian "Debian" \
      3>&1 1>&2 2>&3)
    clear
    log_internal INFO "Selected distribution: $ROOTFS_DISTRO"

    if [ "$ROOTFS_DISTRO" = "ubuntu" ]; then
      exec 3>&1
      ROOTFS_VERSION=$(dialog --menu "Choose Ubuntu version:" $DIALOG_HEIGHT $DIALOG_WIDTH 4 \
        noble "Ubuntu 24.04 (Noble)" \
        jammy "Ubuntu 22.04 (Jammy)" \
        focal "Ubuntu 20.04 (focal)" \
        3>&1 1>&2 2>&3)
    else
      exec 3>&1
      ROOTFS_VERSION=$(dialog --menu "Choose Debian version:" $DIALOG_HEIGHT $DIALOG_WIDTH 4 \
        bookworm "Debian 12 (Bookworm)" \
        bullseye "Debian 11 (Bullseye)" \
        3>&1 1>&2 2>&3)
    fi

    clear
    log_internal INFO "Selected rootfs version: $ROOTFS_VERSION"
    export ROOTFS_DISTRO ROOTFS_VERSION
  fi
}

select_rootfs_distro() {
  exec 3>&1
  ROOTFS_DISTRO=$(dialog --menu "Choose rootfs base distro:" $DIALOG_HEIGHT $DIALOG_WIDTH 5 \
    ubuntu "Ubuntu base (recommended)" \
    debian "Debian base" \
    3>&1 1>&2 2>&3)
  clear
  log_internal INFO "Selected rootfs distro: $ROOTFS_DISTRO"
}

select_rootfs_version() {
  if [ "$ROOTFS_DISTRO" = "ubuntu" ]; then
    exec 3>&1
    ROOTFS_VERSION=$(dialog --menu "Select Ubuntu version:" $DIALOG_HEIGHT $DIALOG_WIDTH 6 \
       noble "Ubuntu 24.04 (Noble)" \
       jammy "Ubuntu 22.04 (Jammy)" \
       focal "Ubuntu 20.04 (focal)" \
      3>&1 1>&2 2>&3)
  else
    exec 3>&1
    ROOTFS_VERSION=$(dialog --menu "Select Debian version:" $DIALOG_HEIGHT $DIALOG_WIDTH 6 \
      bookworm "Debian 12 (Stable)" \
      bullseye "Debian 11 (Old Stable)" \
      3>&1 1>&2 2>&3)
  fi

  if [ "$ROOTFS_VERSION" = "custom" ]; then
    ROOTFS_VERSION=$(dialog --inputbox "Enter custom version (e.g. sid or unstable):" 8 50 3>&1 1>&2 2>&3)
  fi

  clear
  log_internal INFO "Selected rootfs version: $ROOTFS_VERSION"
}

launch_build() {
  OUTPUT_DIR="$(pwd)/OUT-${BOARD}"
  export OUTPUT_DIR
  log_internal INFO "Build directory: $OUTPUT_DIR"

  # Step 1: Prepare sources
  log_internal INFO "Running prepare_sources.sh for $CHIP_FAMILY..."
  ./prepare_sources.sh || {
    log_internal ERROR "prepare_sources.sh failed. Aborting."
    exit 1
  }

  # Step 2: Compile U-Boot/Kernel
  if [ "$CHIP_FAMILY" = "rockchip" ]; then
    COMPILE_SCRIPT="./rk-compile.sh"
  elif [ "$CHIP_FAMILY" = "sunxi" ]; then
    COMPILE_SCRIPT="./sunxi-compile.sh"
  else
    log_internal ERROR "Unsupported CHIP_FAMILY: $CHIP_FAMILY"
    exit 1
  fi

  env CHIP_FAMILY="$CHIP_FAMILY" BOARD="$BOARD" CHIP="$CHIP" ARCH="$ARCH" \
    CROSS_COMPILE="$CROSS_COMPILE" UBOOT_DEFCONFIG="$UBOOT_DEFCONFIG" \
    KERNEL_DEFCONFIG="$KERNEL_DEFCONFIG" DEVICE_TREE="$DEVICE_TREE" \
    KERNEL_VERSION="$KERNEL_VERSION" BUILD_OPTION="$BUILD_OPTION" \
    ROOTFS_METHOD="$ROOTFS_METHOD" ROOTFS_SOURCE="$ROOTFS_SOURCE" \
    ROOTFS_VERSION="$ROOTFS_VERSION" OUTPUT_DIR="$OUTPUT_DIR" \
    $COMPILE_SCRIPT "$BUILD_OPTION"

  # Step 3: Build RootFS (if requested)
  if [[ "$BUILD_OPTION" == "rootfs" || "$BUILD_OPTION" == "all" ]]; then
    log_internal INFO "Running setup_rootfs.sh to build root filesystem..."
    env BOARD="$BOARD" ARCH="$ARCH" \
        ROOTFS_METHOD="$ROOTFS_METHOD" \
        ROOTFS_VERSION="$ROOTFS_VERSION" \
        OUTPUT_DIR="$OUTPUT_DIR" \
        ./setup_rootfs.sh || {
          log_internal ERROR "setup_rootfs.sh failed. Aborting."
          exit 1
        }
  fi

}

finish_and_exit() {
  BUILD_END_TIME=$(date +%s)
  ELAPSED=$((BUILD_END_TIME - BUILD_START_TIME))
  log_internal INFO "Total build time: $((ELAPSED / 60))m $((ELAPSED % 60))s"
}

ascii_logo() {
cat <<'EOF'


  ___  _________  ___  ___________  _____ 
 / _ \ | ___ \  \/  | /  ___| ___ \/  __ \
/ /_\ \| |_/ / .  . | \ `--.| |_/ /| /  \/
|  _  ||    /| |\/| |  `--. \ ___ \| |    
| | | || |\ \| |  | | /\__/ / |_/ /| \__/\
\_| |_/\_| \_\_|  |_/ \____/\____/  \____/
                                          
    A R M - S B C   Linux Build System   
                                  
EOF
}

main() {
  clear
  ascii_logo
  sleep 2
  check_dialog_installed
  select_family

  while true; do
    select_board

    while true; do
      select_build_option

      if [[ "$BUILD_OPTION" == "go_back" ]]; then
        log_internal WARN "Returning to board selection..."
        break  # goes back to select_board
      fi

      break 2  # exits both loops if a real build option was selected
    done
  done

  select_kernel_version

  if [[ "$BUILD_OPTION" == "rootfs" || "$BUILD_OPTION" == "all" ]]; then
    select_rootfs_method
  fi

  load_board_config
  save_config
  launch_build
  finish_and_exit
}

main


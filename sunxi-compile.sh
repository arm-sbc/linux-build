#!/bin/bash

SCRIPT_NAME="sunxi-compile.sh"
BUILD_START_TIME=$(date +%s)

# --- Unified Logging Setup ---
: "${LOG_FILE:=build.log}"  # fallback if not exported
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

# --- Aliases ---
info()    { log_internal INFO "$@"; }
warn()    { log_internal WARN "$@"; }
error()   { log_internal ERROR "$@"; exit 1; }
debug()   { log_internal DEBUG "$@"; }
success() { log_internal PROMPT "$@"; }
log()     { log_internal INFO "$@"; }

# --- Validate environment ---
if [ -z "$BOARD" ] || [ -z "$CHIP" ] || [ -z "$UBOOT_DEFCONFIG" ]; then
  error "Required environment variables not set. Please run set_env.sh first."
fi

# --- Globals ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/OUT"

# Function to check cross-compiler
check_cross_compiler() {
  log "Checking cross-compiler for $CHIP..."
  if command -v "${CROSS_COMPILE}gcc" &>/dev/null; then
    CROSS_COMPILER_VERSION=$(${CROSS_COMPILE}gcc --version | head -n 1)
    log "Using cross-compiler: $CROSS_COMPILER_VERSION"
  else
    error "Cross-compiler '${CROSS_COMPILE}gcc' not found. Please install it."
  fi
}

apply_uboot_patches() {
  log "Starting U-Boot patch application process..."
  PATCH_DIR="patches/sunxi/uboot"

  if [[ ! -d "$PATCH_DIR" ]]; then
    log "Patch directory $PATCH_DIR not found. Skipping U-Boot patch application."
    return
  fi

  log "Applying U-Boot patches from $PATCH_DIR..."
  for patch in "$PATCH_DIR"/*.patch; do
    [ -f "$patch" ] || continue
    log "Applying patch $patch..."
    (
      cd u-boot || error "Failed to enter U-Boot directory."
      patch -Np0 -i "../$patch" || log "Patch $patch already applied or conflicts detected. Skipping."
    )
  done

  log "U-Boot patch application process completed."
}

apply_kernel_patches() {
  log "Starting kernel patch application process..."
  PATCH_DIR="patches/sunxi/kernel"

  if [[ ! -d "$PATCH_DIR" ]]; then
    log "Patch directory $PATCH_DIR not found. Skipping kernel patch application."
    return
  fi

  log "Applying kernel patches from $PATCH_DIR..."
  for patch in "$PATCH_DIR"/*.patch; do
    [ -f "$patch" ] || continue
    log "Applying patch $patch..."
    (
      cd "linux-$KERNEL_VERSION" || error "Failed to enter kernel directory."
      patch -Np1 -i "../$patch" || log "Patch $patch already applied or conflicts detected. Skipping."
    )
  done

  log "Kernel patch application process completed."
}

# Function to dynamically add DTB entry to Makefile
add_dtb_entry() {
  MAKEFILE_PATH="u-boot/arch/arm/dts/Makefile"
  NEW_DTB_ENTRY="${DEVICE_TREE%.dts}.dtb"

  # Find the correct family section in the Makefile
  FAMILY_SECTION=$(grep -P "dtb-\$\(CONFIG_MACH_${PROCESSOR_FAMILY^^}\)" "$MAKEFILE_PATH")

  if [[ -z "$FAMILY_SECTION" ]]; then
    echo "[ERROR] Family section for ${PROCESSOR_FAMILY^^} not found in the Makefile."
    return 1
  fi

  # Check if DTB entry already exists
  if grep -q "$NEW_DTB_ENTRY" "$MAKEFILE_PATH"; then
    echo "[INFO] DTB entry $NEW_DTB_ENTRY already exists. Skipping addition."
  else
    # Append new DTB entry under the correct section
    sed -i "/${FAMILY_SECTION}/a \\    $NEW_DTB_ENTRY \\" "$MAKEFILE_PATH"
    echo "[INFO] Added $NEW_DTB_ENTRY to Makefile under $FAMILY_SECTION."
  fi
}

compile_atf() {
  if [[ "$ARCH" != "arm64" ]]; then
    log "Skipping ATF compilation: Not required for $ARCH."
    return
  fi

  if [[ "$BUILD_OPTION" != "uboot" && "$BUILD_OPTION" != "all" ]]; then
    log "Skipping ATF compilation for build option: $BUILD_OPTION"
    return
  fi

  # Determine platform name for ATF build
  if [[ "$CHIP" == a* ]]; then
    # Allwinner: use PROCESSOR_FAMILY as platform
    PLATFORM="$PROCESSOR_FAMILY"
  else
    # Rockchip or others: use map_chip_to_platform function
    PLATFORM=$(map_chip_to_platform)
  fi

  BL31_PATH="trusted-firmware-a/build/${PLATFORM}/release/bl31.bin"

  # Use prebuilt BL31 if it exists
  if [ -f "$BL31_PATH" ]; then
    log "BL31 already exists at $BL31_PATH. Skipping ATF compilation."
    export BL31="$SCRIPT_DIR/$BL31_PATH"
    return
  fi

  log "Compiling Trusted Firmware for $CHIP (Platform: $PLATFORM)..."
  cd trusted-firmware-a || error "Failed to enter ATF directory."

  make CROSS_COMPILE="$CROSS_COMPILE" PLAT="$PLATFORM" DEBUG=0 bl31 -j$(nproc) || error "Trusted Firmware compilation failed."

  export BL31="$SCRIPT_DIR/$BL31_PATH"
  if [ ! -f "$BL31" ]; then
    error "BL31 file not found after compilation. Expected path: $BL31"
  fi

  cd - > /dev/null
  log "Trusted Firmware compiled successfully. BL31 is at $BL31."
}

# Function to compile U-Boot
compile_uboot() {
  if [[ "$BUILD_OPTION" != "uboot" && "$BUILD_OPTION" != "all" ]]; then
    log "Skipping U-Boot compilation for build option: $BUILD_OPTION"
    return
  fi

  log "Compiling U-Boot for $CHIP ($PROCESSOR_FAMILY family)..."
  cd u-boot || error "Failed to enter U-Boot directory."

  # Apply patches based on processor family if necessary
  if [ -d "patches/$PROCESSOR_FAMILY" ]; then
    log "Applying patches for $PROCESSOR_FAMILY..."
    for patch in patches/$PROCESSOR_FAMILY/*.patch; do
      git apply "$patch" || log "Failed to apply patch: $patch"
    done
  fi

  # Configure U-Boot
  log "Configuring U-Boot with $UBOOT_DEFCONFIG..."
  make CROSS_COMPILE="$CROSS_COMPILE" "$UBOOT_DEFCONFIG" || error "Failed to configure U-Boot."

  # Ensure DEVICE_TREE is set and strip .dts extension
  if [[ -z "$DEVICE_TREE" ]]; then
    error "DEVICE_TREE is not set. Ensure the correct value is exported from set_env.sh."
  fi
  DEVICE_TREE_NAME="${DEVICE_TREE%.dts}"

  log "Using DEVICE_TREE: $DEVICE_TREE_NAME"

  # Handle BL31 for ARM64
  BL31_ARG=""
  if [[ "$ARCH" == "arm64" ]]; then
    if [ -z "$BL31" ]; then
      error "BL31 is not set. Ensure Trusted Firmware (ATF) is compiled and exported before building U-Boot."
    fi

    if [ ! -f "$BL31" ]; then
      error "BL31 binary not found at $BL31. Check the ATF build process."
    fi

    log "Using BL31 located at: $BL31"
    BL31_ARG="BL31=$BL31"
  fi

  # Handle SCP for A64
  SCP_ARG=""
  if [[ "$CHIP" == "a64" ]]; then
    log "Handling SCP for A64 chip..."
    if [ ! -d "../crust" ]; then
      log "Crust repository not found. Cloning it..."
      git clone https://github.com/arm-sbc/crust.git ../crust || error "Failed to clone Crust repository."
    else
      log "Crust repository already exists. Skipping clone."
    fi

    SCP_FILE="../crust/scp.bin"
    if [ ! -f "$SCP_FILE" ]; then
      error "SCP file not found at $SCP_FILE. Ensure Crust is built correctly."
    fi

    log "Using SCP file located at: $SCP_FILE"
    SCP_ARG="SCP=$SCP_FILE"
  fi

  # Build U-Boot with stripped DEVICE_TREE name, BL31, and SCP for A64
  log "Building U-Boot with DEVICE_TREE=$DEVICE_TREE_NAME..."
  make CROSS_COMPILE="$CROSS_COMPILE" DEVICE_TREE="$DEVICE_TREE_NAME" $BL31_ARG $SCP_ARG -j$(nproc) || error "U-Boot compilation failed."

  # Copy the Sunxi-specific output file to the exported output directory
  log "Copying U-Boot output files to OUT directory: $OUT_DIR"
  cp u-boot-sunxi-with-spl.bin "$OUTPUT_DIR/" || error "Failed to copy u-boot-sunxi-with-spl.bin to $OUTPUT_DIR."
  log "U-Boot compilation and output copying completed successfully."
  cd - >/dev/null
}

compile_kernel() {
  log "Compiling Linux kernel for $BOARD ($CHIP)..."

  KERNEL_DIR="linux-${KERNEL_VERSION}"
  if [ ! -d "$KERNEL_DIR" ]; then
    error "Kernel source directory not found: $KERNEL_DIR."
  fi

  cd "$KERNEL_DIR" || error "Failed to enter kernel source directory."

  # Configure the kernel
  cp "../custom_configs/defconfig/$KERNEL_DEFCONFIG" .config || error "Failed to copy defconfig."
  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig || error "Kernel configuration failed."

  # Prompt for running menuconfig
  echo -e "\033[1;33mDo you want to modify the kernel configuration using menuconfig? [y/N]:\033[0m"
  read -r RUN_MENUCONFIG
  if [[ "$RUN_MENUCONFIG" =~ ^[Yy]$ ]]; then
    log "Launching menuconfig..."
    make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" menuconfig || error "menuconfig failed."
    log "menuconfig completed. Continuing with kernel compilation..."
  else
    log "Skipping menuconfig."
  fi
  
# Debug log
log "OUTPUT_DIR is set to: $OUTPUT_DIR"
ls -ld "$OUTPUT_DIR" || error "OUTPUT_DIR does not exist or cannot be accessed."

# Copy the updated .config to the OUTPUT_DIR
CONFIG_OUTPUT="$OUTPUT_DIR/config-$KERNEL_VERSION"
if [ -f ".config" ]; then
  log "Copying .config to $CONFIG_OUTPUT..."
  cp .config "$CONFIG_OUTPUT" || error "Failed to copy updated .config to $CONFIG_OUTPUT."
  log "Copied updated kernel configuration to $CONFIG_OUTPUT."
else
  error ".config file not found after kernel configuration."
fi

  # Dynamically get the kernel version
  KERNEL_VERSION=$(make -s kernelrelease)
  log "Detected kernel version: $KERNEL_VERSION"

  # Set the kernel image type
  if [[ "$ARCH" == "arm64" ]]; then
    KERNEL_IMAGE="Image"
  else
    KERNEL_IMAGE="zImage"
  fi

# Compile the kernel and modules
log "Compiling kernel and modules..."
make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" -j$(nproc) "$KERNEL_IMAGE" modules || error "Kernel compilation failed."
make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" INSTALL_MOD_PATH="$OUTPUT_DIR" modules_install || error "Module installation failed."

# Verify and log installed modules directory
KERNEL_MODULES_SRC="$OUTPUT_DIR/lib/modules/$KERNEL_VERSION"
if [ -d "$KERNEL_MODULES_SRC" ]; then
  log "Kernel modules directory found at $KERNEL_MODULES_SRC."
else
  error "Kernel modules directory not found: $KERNEL_MODULES_SRC"
fi

# Copy the kernel image to the output directory
log "Copying kernel image to OUTPUT_DIR..."
cp "arch/$ARCH/boot/$KERNEL_IMAGE" "$OUTPUT_DIR/" || error "Failed to copy $KERNEL_IMAGE to $OUTPUT_DIR."
log "Copied $KERNEL_IMAGE to $OUTPUT_DIR."

# Copy System.map with version suffix
SYSTEM_MAP="System.map"
SYSTEM_MAP_VERSIONED="$OUTPUT_DIR/System.map-$KERNEL_VERSION"
if [ -f "$SYSTEM_MAP" ]; then
  cp "$SYSTEM_MAP" "$SYSTEM_MAP_VERSIONED" || error "Failed to copy System.map to $OUTPUT_DIR with version suffix."
  log "Copied System.map to $OUTPUT_DIR as System.map-$KERNEL_VERSION."
else
  log "System.map file not found."
fi

log "Kernel compilation completed successfully."

  cd - >/dev/null
}

# Function to compile DTS files for Sunxi/Allwinner boards
compile_dts() {
  log "Starting DTS compilation for Allwinner boards..."

  # Resolve the absolute script directory
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Ensure DEVICE_TREE and ARCH are set
  if [ -z "$DEVICE_TREE" ] || [ -z "$ARCH" ]; then
    error "DEVICE_TREE or ARCH is not set. Ensure both variables are properly configured."
  fi

  # Determine DTS source directory based on architecture
  if [ "$ARCH" = "arm64" ]; then
    DTS_SOURCE_DIR="$SCRIPT_DIR/custom_configs/dts/sunxi/arm64"
    DTS_PATH="$SCRIPT_DIR/linux-${KERNEL_VERSION}/arch/arm64/boot/dts/armsbc"
    DTS_MAIN_MAKEFILE="$SCRIPT_DIR/linux-${KERNEL_VERSION}/arch/arm64/boot/dts/Makefile"
  elif [ "$ARCH" = "arm" ]; then
    DTS_SOURCE_DIR="$SCRIPT_DIR/custom_configs/dts/sunxi/arm32"
    DTS_PATH="$SCRIPT_DIR/linux-${KERNEL_VERSION}/arch/arm/boot/dts/armsbc"
    DTS_MAIN_MAKEFILE="$SCRIPT_DIR/linux-${KERNEL_VERSION}/arch/arm/boot/dts/Makefile"
  else
    error "Unsupported architecture: $ARCH for Allwinner boards."
  fi

  # Verify the DTS source directory
  if [ ! -d "$DTS_SOURCE_DIR" ]; then
    error "DTS source directory not found: $DTS_SOURCE_DIR. Ensure the directory exists."
  fi

  # Create the armsbc directory if it doesn't exist
  if [ ! -d "$DTS_PATH" ]; then
    log "Creating DTS directory: $DTS_PATH"
    mkdir -p "$DTS_PATH" || error "Failed to create DTS directory: $DTS_PATH"
  fi

  # Copy all files from the source directory to the kernel DTS directory
  log "Copying all DTS files to kernel DTS directory: $DTS_PATH"
  cp -r "$DTS_SOURCE_DIR/"* "$DTS_PATH/" || error "Failed to copy DTS files to $DTS_PATH."
  log "All DTS files copied from $DTS_SOURCE_DIR to $DTS_PATH"

  # Add the 'armsbc' entry to the main DTS Makefile
  if ! grep -q "subdir-y += armsbc" "$DTS_MAIN_MAKEFILE"; then
    echo "subdir-y += armsbc" >> "$DTS_MAIN_MAKEFILE"
    log "Added 'subdir-y += armsbc' to $DTS_MAIN_MAKEFILE"
  fi

  # Compile the DTB using the kernel build system
  log "Compiling DTS files using kernel build system..."
  cd "$SCRIPT_DIR/linux-${KERNEL_VERSION}" || error "Failed to enter kernel source directory."
  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" dtbs || error "Failed to compile DTBs."

  # Verify and move the generated DTB file
  GENERATED_DTB="$DTS_PATH/$(basename "${DEVICE_TREE%.dts}.dtb")"
  if [ -f "$GENERATED_DTB" ]; then
    log "Generated DTB file: $GENERATED_DTB"
    mv "$GENERATED_DTB" "$OUTPUT_DIR/" || error "Failed to move DTB file to OUT directory."
    log "DTB file moved to OUT directory: $OUTPUT_DIR/$(basename "$GENERATED_DTB")"
  else
    error "DTB file not created: $GENERATED_DTB"
  fi

  log "DTS compilation completed successfully for Allwinner boards."
}

# Main script execution
case "$1" in
  uboot)
    BUILD_OPTION="uboot"
    check_cross_compiler
    compile_atf
    apply_uboot_patches
    add_dtb_entry
    compile_uboot
    ;;
  kernel)
    BUILD_OPTION="kernel"
    check_cross_compiler
    apply_kernel_patches
    compile_kernel
    compile_dts
    ;;    
  uboot+kernel)
    BUILD_OPTION="uboot+kernel"
    compile_atf
    apply_uboot_patches
    compile_uboot
    apply_kernel_patches
    compile_kernel
    compile_dts
    ;;
  all)
    BUILD_OPTION="all"
    check_cross_compiler
    compile_atf
    apply_uboot_patches
    compile_uboot
    apply_kernel_patches
    compile_kernel
    compile_dts
    ;;
  *)
    error "Invalid argument. Use 'uboot', 'kernel', or 'all'."
    ;;
esac

log "Compilation process completed successfully."

BUILD_END_TIME=$(date +%s)
BUILD_DURATION=$((BUILD_END_TIME - BUILD_START_TIME))
minutes=$((BUILD_DURATION / 60))
seconds=$((BUILD_DURATION % 60))
success "$SCRIPT_NAME completed in ${minutes}m ${seconds}s"
info "Exiting script: $SCRIPT_NAME"
exit 0


#!/bin/bash
SCRIPT_NAME="postinstall-desktop.sh"
BUILD_START_TIME=$(date +%s)
# --- Color Logging ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# --- Input Variables ---
ROOTFS_DIR="$1"
ARCH="$2"
QEMU_BIN="$3"
VERSION="$4"

# --- Validation ---
if [ -z "$ROOTFS_DIR" ] || [ -z "$ARCH" ] || [ -z "$QEMU_BIN" ] || [ -z "$VERSION" ]; then
    error "Usage: $0 <rootfs_dir> <arch> <qemu_bin> <version>"
    exit 1
fi

if [ "$ROOTFS_DIR" = "/" ]; then
    error "Refusing to operate on ROOTFS_DIR=/ — this could destroy your system."
    exit 1
fi

if [ ! -f "$QEMU_BIN" ]; then
    error "QEMU binary not found at $QEMU_BIN"
    exit 1
fi

# --- Setup ---
info "Copying QEMU binary..."
sudo cp "$QEMU_BIN" "$ROOTFS_DIR/usr/bin/"

info "Ensuring /tmp exists with correct permissions..."
sudo mkdir -p "$ROOTFS_DIR/tmp"
sudo chmod 1777 "$ROOTFS_DIR/tmp"

info "Fixing permissions and ownership before chroot..."
sudo chown root:root "$ROOTFS_DIR"
sudo chown -R root:root "$ROOTFS_DIR/etc" "$ROOTFS_DIR/var" "$ROOTFS_DIR/usr" "$ROOTFS_DIR/bin" "$ROOTFS_DIR/sbin" "$ROOTFS_DIR/lib"
sudo chmod 4755 "$ROOTFS_DIR/usr/bin/sudo" 2>/dev/null || true
sudo chmod 440 "$ROOTFS_DIR/etc/sudoers" 2>/dev/null || true
sudo find "$ROOTFS_DIR/etc/sudoers.d" -type f -exec chmod 440 {} + 2>/dev/null
sudo chown -R 1000:1000 "$ROOTFS_DIR/home/ubuntu" 2>/dev/null || true

info "Binding /dev, /proc, /sys..."
sudo mount --bind /dev "$ROOTFS_DIR/dev"
sudo mount --bind /proc "$ROOTFS_DIR/proc"
sudo mount --bind /sys "$ROOTFS_DIR/sys"

info "Setting static DNS (8.8.8.8) inside rootfs..."
sudo rm -f "$ROOTFS_DIR/etc/resolv.conf"
cat <<EOF | sudo tee "$ROOTFS_DIR/etc/resolv.conf" > /dev/null
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

# --- Chroot and Configure ---
info "Starting chroot configuration..."

sudo chroot "$ROOTFS_DIR" /bin/bash -c '
set -e

# --- 1. Set Hostname ---
HOSTNAME=$(echo "$CHIP" | tr '[:upper:]' '[:lower:]')
echo "[INFO] Setting hostname..."
echo "'"$HOSTNAME"'" > /etc/hostname
if grep -q "^127.0.1.1" /etc/hosts; then
    sed -i "s/^127.0.1.1.*/127.0.1.1    '"$HOSTNAME"'/" /etc/hosts
else
    echo "127.0.1.1    '"$HOSTNAME"'" >> /etc/hosts
fi

# --- 2. Configure Locales ---
echo "[INFO] Configuring locales..."
apt-get install -y locales
sed -i "s/^# *en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

# --- 3. Create 'ubuntu' user ---
echo "[INFO] Creating user 'ubuntu'..."
if ! id ubuntu &>/dev/null; then
    useradd -m -s /bin/bash ubuntu
    echo "ubuntu:ubuntu" | chpasswd
else
    echo "[INFO] User 'ubuntu' already exists."
fi

usermod -aG sudo ubuntu

# --- 4. Passwordless sudo ---
echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/99-ubuntu-user
chmod 0440 /etc/sudoers.d/99-ubuntu-user

echo "[INFO] Updating package lists..."
apt update

# --- 5. Install Essential Packages ---
echo "[INFO] Installing essential packages..."
ESSENTIAL_PACKAGES="openssh-server gpiod alsa-utils fdisk nano i2c-tools util-linux-extra"
if ! DEBIAN_FRONTEND=noninteractive apt-get install -y $ESSENTIAL_PACKAGES; then
    echo "[WARN] Some packages failed to install."
    read -p "Continue anyway? [Y/n]: " CONT
    [[ "$CONT" =~ ^[Nn]$ ]] && exit 1
fi

# --- 6. Install LXQt Desktop and LightDM ---
echo "[INFO] Installing LXQt and LightDM..."
DEBIAN_FRONTEND=noninteractive apt-get install -y lxqt lightdm xinit blueman nm-tray

# --- 7. LightDM autologin ---
echo "[INFO] Enabling autologin..."
mkdir -p /etc/lightdm/lightdm.conf.d
cat <<AUTOLOGIN > /etc/lightdm/lightdm.conf.d/50-autologin.conf
[Seat:*]
autologin-user=ubuntu
autologin-user-timeout=0
user-session=lxqt
AUTOLOGIN

# --- 8. Configure Netplan for NetworkManager (Ethernet + Wi-Fi) ---
echo "[INFO] Setting up Netplan with NetworkManager..."
rm -f /etc/netplan/*.yaml
mkdir -p /etc/netplan
cat <<EOF > /etc/netplan/01-network-manager.yaml
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    default:
      match:
        name: "e*"
      dhcp4: true
EOF

# --- 9. Cleanup ---
echo "[INFO] Cleaning up..."
apt purge -y nftables accountsservice || true
apt autoremove -y --purge || true
apt clean
rm -rf /var/lib/apt/lists/*
'
# --- Cleanup ---
info "Unmounting /dev, /proc, /sys..."
sudo umount "$ROOTFS_DIR/dev"
sudo umount "$ROOTFS_DIR/proc"
sudo umount "$ROOTFS_DIR/sys"

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

success "✅ Post-installation complete: Desktop, hostname, and permissions are configured safely."

# --- Script Footer ---
BUILD_END_TIME=$(date +%s)
BUILD_DURATION=$((BUILD_END_TIME - BUILD_START_TIME))
minutes=$((BUILD_DURATION / 60))
seconds=$((BUILD_DURATION % 60))

success "✅ Desktop post-install completed in ${minutes}m ${seconds}s"
info "Exiting script: $SCRIPT_NAME"
exit 0


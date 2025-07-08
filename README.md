<p align="center">
  <img src="https://github.com/arm-sbc/binaries/raw/4c90a82d521facf25e208e4319aa818ec815b6f4/ARM_SBC_LOGO.jpg" alt="ARM-SBC Logo" width="300"/>
</p>

# ARM-SBC Linux Build Scripts

This repository contains scripts to automate the process of compiling **U-Boot**, the **Linux kernel**, and generating **bootable SD/eMMC images** for various **ARM-SBC boards** (SBCs), including Rockchip and Allwinner platforms.

---

## 🚀 Getting Started

```bash
sudo apt install git dialog curl
git clone https://github.com/arm-sbc/linux-build.git
cd linux-build
./arm_build.sh
```

The script will guide you through selecting your board, SoC, kernel version, and desired build steps.

## ✅ Features

- 🌟 Interactive board selection for Rockchip and Allwinner
- 🛠️ Builds U-Boot, kernel, and optionally rootfs
- ⚙️ Applies patches and defconfigs automatically
- 💾 Creates bootable SD/eMMC images
- 🐧 Supports both legacy and mainline kernel options
- 🖥️ Optional LXQt desktop setup with network auto-config

---

## 📦 Dependencies

All required build tools and packages will be installed automatically.

However, depending on your Linux distribution, you may need to install some packages manually, especially on non-Ubuntu systems.

> ⚠️ We recommend using **Ubuntu 22.04 or newer** for best compatibility.


## 🆘 Support
For any issues, feature requests, or integration help, please contact us:

📧 support@arm-sbc.com

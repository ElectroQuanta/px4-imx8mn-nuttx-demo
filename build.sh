#!/bin/bash

DIR="$PWD"
PX4_URL="https://github.com/ElectroQuanta/PX4-Autopilot.git"
PX4_REPO="PX4-mine"
PX4_DIR="$DIR/$PX4_REPO"
PX4_BRANCH="eq/imx8mn-port"
PX4_NUTTX_DIR="$DIR/$PX4_REPO/platforms/nuttx/NuttX/nuttx"
PX4_NUTTX_BRANCH="imx8mn-px4-1_16"
UBOOT="$DIR/uboot-imx"
ATF="$DIR/imx-atf"
FW_VER="8.9"
FW_IMX="firmware-imx-$FW_VER"
FW="$DIR/$FW_IMX"
MKIMG="$DIR/imx-mkimage"
MKIMG_IMX="$DIR/imx-mkimage/iMX8M"

export CROSS_COMPILE=aarch64-linux-gnu-
export ARCH=aarch64

##################### Pretty print ###################
# Define ANSI escape codes for syntax highlighting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
ORANGE='\033[0;91m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

echo_with_syntax_highlighting() {
	local color="$1"
	local text="$2"
	echo -e "${color}${text}${RESET}"
}

pr_info() {
	echo_with_syntax_highlighting "$GREEN$BOLD" "[imx8mn-boot]: $1"
}

pr_warn() {
	echo_with_syntax_highlighting "$YELLOW$BOLD" "[imx8mn-boot]: $1"
}

pr_error() {
	echo_with_syntax_highlighting "$RED$BOLD" "[imx8mn-boot]: $1"
}

########################################################################
# 0) Setup environment
########################################################################
clean_build(){
	rm -rf "$UBOOT" "$ATF" "$MKIMG" "$FW_IMX" 2>/dev/null
}

print_env(){
	pr_info "UBOOT = $UBOOT"
	pr_info "ATF = $ATF"
	pr_info "FW_VER = $FW_VER"
	pr_info "FW = $FW"
	pr_info "MKIMG = $MKIMG"
	pr_info "MKIMG_IMX = $MKIMG_IMX"

}

########################################################################
# 1) Build PX4
########################################################################
px4_build() {
	# Clone my PX4-Autopilot fork
    git clone "${PX4_URL}" "${PX4_REPO}"
	
	# Checkout to imx8mn-port branch and updates all submodules
    cd "$PX4_DIR"
    git checkout eq/imx8mn-port
    git submodule update --init --recursive

	# Enter Nuttx repo submodule and switch to port branch
     cd "$PX4_NUTTX_DIR"
     git switch imx8mn-px4-1_16

	 # Build nuttx.bin
	 make distclean && ./tools/configure.sh -l mx8mn-ddr3l-evk:nsh && make V=1
}


########################################################################
# 1) Build U-Boot
########################################################################
uboot_build(){
	cd "$DIR"
    pr_info ">> U-Boot"
    git clone https://github.com/nxp-imx/uboot-imx.git --branch=lf_v2023.04 --depth=1
	make -C "$UBOOT" distclean
    make -C "$UBOOT" imx8mn_ddr3l_evk_defconfig
    make -C "$UBOOT" CROSS_COMPILE=aarch64-linux-gnu-
}

########################################################################
# 2) Build ATF
########################################################################
atf_build(){
	cd "$DIR"
    pr_info ">> ATF"
    git clone https://github.com/nxp-imx/imx-atf.git --branch=lf_v2.8 --depth=1
    make -C "$ATF" PLAT=imx8mn bl31 CROSS_COMPILE=aarch64-linux-gnu-
}

#########################################################################
# 3) Get firmwware
########################################################################
fw_build(){
	cd "$DIR"
    pr_info ">> FW"
    wget https://www.nxp.com/lgfiles/NMG/MAD/YOCTO/$FW_IMX.bin
    chmod +x $FW_IMX.bin
    ./$FW_IMX.bin
}

#########################################################################
# 4) Build tool to deploy imx boot image
########################################################################
mkimg_build(){
	cd "$DIR"
    pr_info ">> MKIMG"
    git clone https://github.com/nxp-imx/imx-mkimage --branch lf-6.1.55_2.2.0 --depth 1

    cp -v $UBOOT/tools/mkimage $MKIMG_IMX/mkimage_uboot
    cp -v $UBOOT/spl/u-boot-spl.bin $MKIMG_IMX
    cp -v $UBOOT/u-boot-nodtb.bin $MKIMG_IMX
    cp -v $UBOOT/arch/arm/dts/imx8mn-ddr3l-evk.dtb $MKIMG_IMX/imx8mn-ddr3l-val.dtb
    cp -v $ATF/build/imx8mn/release/bl31.bin $MKIMG_IMX

    # cp -v $FW/firmware/hdmi/cadence/signed_hdmi_imx8m.bin $MKIMG_IMX

    cp -v $FW/firmware/ddr/synopsys/ddr3_dmem_1d.bin $MKIMG_IMX/ddr3_dmem_1d_201810.bin
    cp -v $FW/firmware/ddr/synopsys/ddr3_imem_1d.bin $MKIMG_IMX/ddr3_imem_1d_201810.bin

    # Build
    pr_info ">> MKIMG: Build"
    make -C $MKIMG clean
    make -C $MKIMG SOC=iMX8MN flash_ddr3l_val_no_hdmi
}

#########################################################################
# 5) Format SD card (if required)
########################################################################
format_SD() {
    SD_DEV="$1"
    BOOT_BIN="$2"
    SD="${SD_DEV}"
    PART="${SD}1"

    pr_info ">> Partitioning SD card..."
    sudo wipefs -a "$SD"
    sudo sfdisk "$SD" <<'EOF'
label: dos
unit: sectors
/dev/sda1 : start=8192, size=262144, type=c
/dev/sda2 : start=270336, type=83
EOF

    pr_info ">> Formatting FAT32 boot partition..."
    sudo mkfs.vfat "$PART"

    pr_info ">> Writing flash.bin to ${SD_DEV} (offset 32 KB)..."
    sudo dd if="$BOOT_BIN" of="$SD_DEV" bs=1k seek=32 conv=fsync status=progress
    sync

    pr_info ">> Re-reading partition table..."
    sudo partprobe "$SD_DEV" || true
    sudo udevadm settle || true
    sleep 1
}

#########################################################################
# 6) Deploy to SD card
########################################################################
deploy_SD() {
	cd "$DIR"
    pr_info ">> Deploying to SD card"

    SD_DEV="/dev/sda"
    SD="${SD_DEV}"
    PART="${SD}1"

    BOOT_BIN="$DIR/imx-mkimage/iMX8M/flash.bin"
    NUTTX_BIN="$PX4_NUTTX_DIR/nuttx.bin"
    FAT_MOUNT="/run/media/zmp/sdcard"

    if [ ! -b "$SD_DEV" ]; then
        pr_error "ERROR: $SD_DEV not found."
        exit 1
    fi
    if [ ! -f "$BOOT_BIN" ]; then
        pr_error "ERROR: $BOOT_BIN not found."
        exit 1
    fi
    if [ ! -f "$NUTTX_BIN" ]; then
        pr_info "ERROR: $NUTTX_BIN not found."
        return 1
    fi

	lsblk
    read -p ">> Do you want to format the SD card ($SD_DEV)? [y/N]: " REPLY
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        format_SD "$SD_DEV" "$BOOT_BIN"
    else
        pr_warn ">> Skipping SD card format."
    fi

    pr_info ">> Mounting boot partition..."
    sudo mkdir -p "$FAT_MOUNT"
    sudo umount -f "$FAT_MOUNT" 2>/dev/null || true
    sudo mount "$PART" "$FAT_MOUNT"

    pr_info ">> Copying NuttX binary..."
    sudo cp -v "$NUTTX_BIN" "$FAT_MOUNT"

    pr_info ">> Syncing & unmounting..."
    sync
    sudo umount "$FAT_MOUNT"
	# sudo eject "$SD_DEV"

    pr_info ">> SD card deployment complete!"
}

#clean_build
px4_build
uboot_build
atf_build
fw_build
mkimg_build
deploy_SD

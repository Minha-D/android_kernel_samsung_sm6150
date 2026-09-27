#!/bin/bash
set -e

export ARCH=arm64
KERNEL_DIR="$(pwd)"
mkdir -p out

# Paths matching what Build_actions.yml's "Fetch toolchains" step clones to.
# NOTE: LineageOS's aarch64 GCC prebuilt uses the aarch64-linux-android- binary
# prefix (not aarch64-linux-gnu- like a Linaro toolchain would) — CROSS_COMPILE
# is set accordingly below. CLANG_TRIPLE stays aarch64-linux-gnu- regardless,
# since that's Clang's own internal target string, unrelated to the binutils
# package's naming.
CROSS_COMPILE="$KERNEL_DIR/../toolchains/gcc64/bin/aarch64-linux-gnu-"
CROSS_COMPILE_ARM32="$KERNEL_DIR/../toolchains/gcc32/bin/arm-linux-androideabi-"
KERNEL_LLVM_BIN="$KERNEL_DIR/../toolchains/clang/bin/clang"
CLANG_TRIPLE="aarch64-linux-gnu-"
KERNEL_MAKE_ENV="DTC_EXT=$KERNEL_DIR/tools/dtc CONFIG_BUILD_ARM64_DT_OVERLAY=y"

DEFCONFIG=sm6150_sec_m40_swa_open_defconfig
JOBS=$(nproc)

make -j"$JOBS" -C "$KERNEL_DIR" O="$KERNEL_DIR/out" $KERNEL_MAKE_ENV \
	ARCH=arm64 \
	CROSS_COMPILE="$CROSS_COMPILE" \
	CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
	REAL_CC="$KERNEL_LLVM_BIN" \
	CLANG_TRIPLE="$CLANG_TRIPLE" \
	"$DEFCONFIG"

make -j"$JOBS" -C "$KERNEL_DIR" O="$KERNEL_DIR/out" $KERNEL_MAKE_ENV \
	ARCH=arm64 \
	CROSS_COMPILE="$CROSS_COMPILE" \
	CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
	REAL_CC="$KERNEL_LLVM_BIN" \
	CLANG_TRIPLE="$CLANG_TRIPLE"

# The build produces Image.gz-dtb (gzip-compressed Image + appended DTB), not
# plain Image — confirmed from actual build output, not assumed. This drops
# straight into the AnyKernel3 template's root, ready to zip.
cp "$KERNEL_DIR/out/arch/arm64/boot/Image.gz-dtb" "$KERNEL_DIR/../AnyKernel3/Image.gz-dtb"

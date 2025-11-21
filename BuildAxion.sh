#!/bin/bash

set -e

### Configuration
ROM_NAME="AxionOS"
MANIFEST_URL="https://github.com/AxionAOSP/android.git"
MANIFEST_BRANCH="lineage-23.0"
ARCH="arm64"
VARIANT="gapps"
BUILD_TYPE="nosu"

### Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}AxionOS Android 16 GSI Build Script${NC}"
echo -e "${GREEN}========================================${NC}"

### Set up build environment
echo -e "${YELLOW}Setting up build environment...${NC}"
export ALLOW_MISSING_DEPENDENCIES=true
export WITHOUT_CHECK_API=true

### Initialize repo (already done in your case)
echo -e "${YELLOW}Repository already initialized${NC}"

### Add TrebleDroid local manifest
echo -e "${YELLOW}Adding TrebleDroid manifests...${NC}"
rm -rf .repo/local_manifests
mkdir -p .repo/local_manifests

cat > .repo/local_manifests/treble.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="treble" fetch="https://github.com/TrebleDroid/" />
  <remote name="phh" fetch="https://github.com/phhusson/" />
  
  <!-- TrebleDroid device tree and overlays -->
  <project path="device/phh/treble" name="device_phh_treble" remote="treble" revision="android-16.0" />
  <project path="vendor/hardware_overlay" name="vendor_hardware_overlay" remote="treble" revision="android-16.0" />
  <project path="vendor/interfaces" name="vendor_interfaces" remote="treble" revision="android-16.0" />
  
  <!-- PHH patches and tools -->
  <project path="external/phh" name="treble_experimentations" remote="phh" revision="android-16.0" />
</manifest>
EOF

### Reduce job count
echo -e "${YELLOW}Syncing sources with reasonable job count...${NC}"
repo sync -c -j12 --force-sync --no-clone-bundle --no-tags --optimized-fetch --prune

### Apply TrebleDroid patches
echo -e "${YELLOW}Applying TrebleDroid patches...${NC}"

# Clone TrebleDroid patches repository
if [ ! -d "treble_aosp" ]; then
    echo "Cloning TrebleDroid patches..."
    git clone https://github.com/ponces/treble_aosp -b android-16.0 treble_aosp
fi

# Apply patches
cd treble_aosp
if [ -f "apply-patches.sh" ]; then
    bash apply-patches.sh ../
else
    # Manual patch application
    for patch_dir in patches/*/; do
        echo "Applying patches from $patch_dir"
        for patch in $patch_dir*.patch; do
            [ -f "$patch" ] || continue
            target_dir=$(basename $(dirname $patch))
            echo "Applying $patch to $target_dir"
            cd ../$target_dir
            git apply --check $patch 2>/dev/null && git apply $patch || echo "Skipped $patch"
            cd -
        done
    done
fi
cd ..

### Set up build environment
echo -e "${YELLOW}Setting up build environment...${NC}"
source build/envsetup.sh

### Configure for GSI build with GApps
echo -e "${YELLOW}Configuring for arm64 GApps build (no root)...${NC}"

# Set AxionOS build flags
export WITH_GMS=true
export TARGET_NO_SU=true
export TARGET_SUPPORTS_GOOGLE_BATTERY=true
export TARGET_BUILD_VARIANT=userdebug

# Lunch for treble GSI
# Format: treble_arm64_bgN = arm64, binder64, gapps, no-su
lunch treble_arm64_bgN-ap3a-userdebug

### Build GSI
echo -e "${YELLOW}Starting build process...${NC}"
echo -e "${YELLOW}Target: arm64 with GApps (no root)${NC}"

# Build the system image
mka systemimage -j$(nproc)

### Package the GSI
echo -e "${YELLOW}Packaging GSI image...${NC}"
BUILD_DATE=$(date +%Y%m%d)
OUTPUT_DIR="$PWD/releases/AxionOS-16.0-$BUILD_DATE"
mkdir -p "$OUTPUT_DIR"

# Find and compress system image
PRODUCT_OUT=$(echo $OUT)
SYSTEM_IMG="$PRODUCT_OUT/system.img"

if [ -f "$SYSTEM_IMG" ]; then
    echo -e "${YELLOW}Compressing system image...${NC}"
    OUTPUT_FILE="$OUTPUT_DIR/AxionOS-16.0-arm64-ab-gapps-nosu-$BUILD_DATE.img.xz"
    xz -9 -T0 -v -c "$SYSTEM_IMG" > "$OUTPUT_FILE"
    
    # Generate checksums
    cd "$OUTPUT_DIR"
    sha256sum *.img.xz > sha256sum.txt
    md5sum *.img.xz > md5sum.txt
    
    # Get file size
    SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
    
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}✓ Build completed successfully!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Output: $OUTPUT_FILE${NC}"
    echo -e "${GREEN}Size: $SIZE${NC}"
    echo -e "${GREEN}========================================${NC}"
else
    echo -e "${RED}Error: System image not found at $SYSTEM_IMG${NC}"
    echo -e "${YELLOW}Looking for alternative locations...${NC}"
    find $PRODUCT_OUT -name "system.img" -o -name "*.img" | head -10
    exit 1
fi

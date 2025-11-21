#!/bin/bash

set -e

### Configuration
ROM_NAME="AxionOS"
ANDROID_VERSION="android-16.0.0_r2"
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

### Initialize repo
echo -e "${YELLOW}Initializing repository...${NC}"
if [ ! -d ".repo" ]; then
    repo init -u $MANIFEST_URL -b $MANIFEST_BRANCH --git-lfs --depth=1
else
    echo "Repository already initialized"
fi

### Add TrebleDroid local manifest
echo -e "${YELLOW}Adding TrebleDroid manifests...${NC}"
mkdir -p .repo/local_manifests

cat > .repo/local_manifests/treble.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="treble" fetch="https://github.com/TrebleDroid/" />
  
  <project path="device/phh/treble" name="device_phh_treble" remote="treble" revision="android-16.0" />
  <project path="vendor/hardware_overlay" name="vendor_hardware_overlay" remote="treble" revision="android-16.0" />
  <project path="vendor/interfaces" name="vendor_interfaces" remote="treble" revision="android-16.0" />
  
  <!-- Remove conflicting AOSP projects -->
  <remove-project name="platform/packages/apps/Launcher3" />
  <remove-project name="platform/packages/apps/Settings" />
</manifest>
EOF

### Sync sources
echo -e "${YELLOW}Syncing sources (this will take a while)...${NC}"
repo sync -c -j$(nproc --all) --force-sync --no-clone-bundle --no-tags --optimized-fetch --prune

### Apply TrebleDroid patches
echo -e "${YELLOW}Applying TrebleDroid patches...${NC}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Clone TrebleDroid patches if not using the treble_aosp repo structure
if [ ! -d "treble_aosp" ]; then
    git clone https://github.com/ponces/treble_aosp -b android-16.0 treble_aosp
fi

# Apply patches from TrebleDroid
if [ -d "treble_aosp/patches" ]; then
    echo "Applying patches..."
    bash treble_aosp/apply-patches.sh treble_aosp/patches || true
fi

### Set up build environment
echo -e "${YELLOW}Setting up build environment...${NC}"
. build/envsetup.sh

### Configure for GSI build
echo -e "${YELLOW}Configuring for arm64 GApps build...${NC}"

# Lunch command for AxionOS with GApps
# For GSI, we use treble device configuration
export WITH_GMS=true
export TARGET_NO_SU=true
export TARGET_SUPPORTS_GOOGLE_BATTERY=true

# Select the appropriate treble variant for arm64
# treble_arm64_bgN = arm64, binder64, gapps, no su
lunch treble_arm64_bgN-ap3a-userdebug

### Build GSI
echo -e "${YELLOW}Starting build process...${NC}"
echo -e "${YELLOW}Building for: arm64 with GApps and no root${NC}"

# Build system image
make -j$(nproc --all) systemimage

### Package the GSI
echo -e "${YELLOW}Packaging GSI image...${NC}"
BUILD_DATE=$(date +%Y%m%d)
OUTPUT_DIR="$PWD/release/AxionOS-16.0-$BUILD_DATE"
mkdir -p "$OUTPUT_DIR"

# Find the built system image
SYSTEM_IMG=$(find out/target/product/tdgsi_arm64_ab -name "system.img" 2>/dev/null | head -1)

if [ -f "$SYSTEM_IMG" ]; then
    # Compress the system image
    echo -e "${YELLOW}Compressing system image...${NC}"
    xz -z -T0 -v "$SYSTEM_IMG" -c > "$OUTPUT_DIR/AxionOS-16.0-arm64-ab-gapps-nosu-$BUILD_DATE.img.xz"
    
    # Generate checksums
    cd "$OUTPUT_DIR"
    sha256sum *.img.xz > sha256sum.txt
    
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Build completed successfully!${NC}"
    echo -e "${GREEN}Output: $OUTPUT_DIR${NC}"
    echo -e "${GREEN}========================================${NC}"
else
    echo -e "${RED}Error: System image not found!${NC}"
    exit 1
fi

#!/bin/bash

rom_fp="$(date +%y%m%d)"

originFolder="$(dirname "$(readlink -f -- "$0")")"

mkdir -p release/$rom_fp/

set -e

if [ -z "$USER" ];then
export USER="$(id -un)"
fi

export LC_ALL=C

# AxionOS manifest configuration - HARDCODED TO ANDROID 16
manifest_url="https://github.com/AxionAOSP/android.git"
axion_branch="lineage-23.0"
aosp_base="android-16.0"
phh_branch="android-16.0"
supp="-bp2a"

echo "========================================"
echo "  AxionOS Android 16 ARM64 GSI Build Bot"
echo "========================================"
echo "Build date: $rom_fp"
echo "Branch: $axion_branch (Android 16)"
echo "Architecture: ARM64 ONLY"
echo "Security Patch: CURRENT ONLY"
echo "Root: NO ROOT (N variants)"
echo "========================================"

# Download GoFile upload script if not present
if [ ! -f upload.sh ]; then
echo "Downloading GoFile upload script..."
wget -q https://raw.githubusercontent.com/Sushrut1101/GoFile-Upload/refs/heads/master/upload.sh && chmod +x upload.sh
fi

# Initialize AxionOS repo
echo "Initializing AxionOS Android 16 repository..."
repo init -u "$manifest_url" -b $axion_branch --git-lfs --depth=1

# Clone TrebleDroid manifest for GSI support
echo "Setting up TrebleDroid manifests..."
if [ -d .repo/local_manifests ] ;then
( cd .repo/local_manifests; git fetch; git reset --hard; git checkout origin/$phh_branch 2>/dev/null || git checkout origin/android-15.0)
else
git clone https://github.com/TrebleDroid/treble_manifest .repo/local_manifests -b $phh_branch 2>/dev/null || \
git clone https://github.com/TrebleDroid/treble_manifest .repo/local_manifests -b android-15.0
fi

echo "Syncing repositories..."
repo sync -c -j$(nproc) --force-sync --no-clone-bundle --no-tags || repo sync -c -j1 --force-sync

# Clone TrebleDroid patches if not present
if [ ! -d patches ]; then
echo "Cloning TrebleDroid patches..."
git clone https://github.com/ponces/treble_aosp patches_repo -b $phh_branch 2>/dev/null || \
git clone https://github.com/ponces/treble_aosp patches_repo -b android-15.0
if [ -d patches_repo/patches ]; then
cp -r patches_repo/patches .
fi
fi

# Apply TrebleDroid patches
if [ -d patches ]; then
echo "Applying TrebleDroid patches..."
if [ -f patches/apply-patches.sh ]; then
bash patches/apply-patches.sh . trebledroid 2>/dev/null || echo "Some patches may have failed, continuing..."
# Apply additional patch sets if they exist
for patch_dir in ponces personal; do
if [ -d patches/$patch_dir ]; then
echo "Applying $patch_dir patches..."
bash patches/apply-patches.sh . $patch_dir 2>/dev/null || echo "Some $patch_dir patches may have failed, continuing..."
fi
done
else
echo "No apply-patches.sh script found, skipping automatic patching"
fi
fi

# Generate Treble device configurations
echo "Generating Treble device configurations..."
(cd device/phh/treble; git clean -fdx; bash generate.sh)

# Build Treble app
echo "Building Treble app..."
if [ -d packages/apps/TrebleApp ]; then
(cd packages/apps/TrebleApp; ./gradlew assembleRelease 2>/dev/null || echo "Treble app build failed, continuing...")
fi

. build/envsetup.sh

# Enable ccache for faster builds
export USE_CCACHE=1
export CCACHE_COMPRESS=1
export CCACHE_MAXSIZE=50G
ccache -M 50G -F 0 2>/dev/null || true

# Array to store built files
declare -a BUILT_FILES=()

# Function to upload file to GoFile
uploadToGoFile() {
local file="$1"
if [ -f "$file" ]; then
echo "Uploading $file to GoFile..."
./upload.sh "$file"
else
echo "File $file not found, skipping upload."
fi
}

buildVariant() {
local lunch_target=$1
local output_name=$2
local build_gapps=$3

echo ""
echo "========================================"
echo "Building: $output_name"
echo "Target: $lunch_target"
echo "GApps: $build_gapps"
echo "========================================"

lunch $lunch_target
make RELAX_USES_LIBRARY_CHECK=true BUILD_NUMBER=$rom_fp installclean

# Set GApps flag if building GApps variant
if [ "$build_gapps" = "true" ]; then
echo "Building with GApps..."
make RELAX_USES_LIBRARY_CHECK=true BUILD_NUMBER=$rom_fp TARGET_BUILD_GAPPS=true -j$(nproc) systemimage
else
echo "Building Vanilla variant..."
make RELAX_USES_LIBRARY_CHECK=true BUILD_NUMBER=$rom_fp -j$(nproc) systemimage
fi

make RELAX_USES_LIBRARY_CHECK=true BUILD_NUMBER=$rom_fp vndk-test-sepolicy

local output_file="release/$rom_fp/system-axion-${output_name}.img.xz"
echo "Compressing system image..."
xz -c $OUT/system.img -T0 > "$output_file"

echo "Build completed: $output_name"
# Store the file path for later upload selection
BUILT_FILES+=("$output_file")
}

repo manifest -r > release/$rom_fp/manifest.xml

# Copy patches if list-patches.sh exists
if [ -f "$originFolder/list-patches.sh" ]; then
bash "$originFolder"/list-patches.sh
if [ -f patches.zip ]; then
cp patches.zip release/$rom_fp/patches-for-developers.zip 2>/dev/null || true
BUILT_FILES+=("release/$rom_fp/patches-for-developers.zip")
fi
fi

# Build Android 16 ARM64 GSI variants (current security patch, NO ROOT)
echo ""
echo "========================================"
echo "Building Android 16 ARM64 GSI Variants"
echo "========================================"

# ARM64 Vanilla NO ROOT (bvN - current security patch)
buildVariant treble_arm64_bvN$supp-userdebug arm64-vanilla false

# ARM64 GApps NO ROOT (bgN - current security patch)
buildVariant treble_arm64_bgN$supp-userdebug arm64-gapps true

# Add manifest to built files
BUILT_FILES+=("release/$rom_fp/manifest.xml")

echo ""
echo "========================================"
echo "  Build Complete!"
echo "========================================"
echo "Built variants:"
echo "  ✓ arm64-vanilla (bvN - NO ROOT)"
echo "  ✓ arm64-gapps (bgN - NO ROOT)"
echo ""
echo "========================================"
echo "  Select Files to Upload to GoFile"
echo "========================================"

# Interactive upload selection
for i in "${!BUILT_FILES[@]}"; do
file="${BUILT_FILES[$i]}"
filename=$(basename "$file")
filesize=$(du -h "$file" 2>/dev/null | cut -f1 || echo "N/A")
echo "[$((i+1))] $filename ($filesize)"
done

echo ""
echo "Options:"
echo "  [a] Upload all files"
echo "  [n] Upload none (skip upload)"
echo "  [1-${#BUILT_FILES[@]}] Upload specific file numbers (space-separated)"
echo ""
read -p "Enter your choice: " choice

case "$choice" in
    a|A)
        echo ""
        echo "Uploading all files to GoFile..."
        for file in "${BUILT_FILES[@]}"; do
            uploadToGoFile "$file"
        done
        ;;
    n|N)
        echo ""
        echo "Skipping upload. Files saved locally in: release/$rom_fp/"
        ;;
    *)
        echo ""
        echo "Uploading selected files..."
        for num in $choice; do
            if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#BUILT_FILES[@]}" ]; then
                uploadToGoFile "${BUILT_FILES[$((num-1))]}"
            else
                echo "Invalid selection: $num (skipped)"
            fi
        done
        ;;
esac

echo ""
echo "========================================"
echo "  All Tasks Complete!"
echo "========================================"
echo "Local files saved in: release/$rom_fp/"
echo "========================================"

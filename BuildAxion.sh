#!/bin/bash

echo
echo "--------------------------------------"
echo " AxionOS 16.0 GSI Buildbot "
echo " Based on ponces AOSP script "
echo "--------------------------------------"
echo

set -e

export BUILD_NUMBER="$(date +%y%m%d)"

[ -z "$OUTPUT_DIR" ] && OUTPUT_DIR="$PWD/output"
[ -z "$BUILD_ROOT" ] && BUILD_ROOT="$PWD"

# Array to store built files
declare -a BUILT_FILES=()

initRepos() {
    echo "--> Initializing AxionOS Android 16 workspace"
    
    # Remove problematic .repo if it exists with conflicts
    if [ -d .repo ]; then
        echo "--> Cleaning existing .repo directory"
        rm -rf .repo/local_manifests
    fi
    
    repo init -u https://github.com/AxionAOSP/android.git -b lineage-23.0 --git-lfs --depth=1
    echo
    
    echo "--> Preparing TrebleDroid local manifest"
    git clone https://github.com/TrebleDroid/treble_manifest .repo/local_manifests -b android-16.0 2>/dev/null || \
    git clone https://github.com/TrebleDroid/treble_manifest .repo/local_manifests -b android-15.0
    echo
}

syncRepos() {
    echo "--> Syncing repos (limited to 24 jobs)"
    repo sync -c --force-sync --no-clone-bundle --no-tags -j24
    echo
}

applyPatches() {
    # Clone patches if not present
    if [ ! -d patches ]; then
        echo "--> Cloning TrebleDroid patches"
        git clone https://github.com/ponces/treble_aosp patches_repo -b android-16.0 2>/dev/null || \
        git clone https://github.com/ponces/treble_aosp patches_repo -b android-15.0
        if [ -d patches_repo/patches ]; then
            cp -r patches_repo/patches .
        fi
    fi
    
    if [ -d patches ] && [ -f patches/apply-patches.sh ]; then
        echo "--> Applying TrebleDroid patches"
        bash patches/apply-patches.sh . trebledroid 2>/dev/null || echo "Some trebledroid patches may have failed"
        echo
        
        echo "--> Applying ponces patches"
        bash patches/apply-patches.sh . ponces 2>/dev/null || echo "Some ponces patches may have failed"
        echo
        
        echo "--> Applying personal patches"
        bash patches/apply-patches.sh . personal 2>/dev/null || echo "Some personal patches may have failed"
        echo
    else
        echo "--> No patches found, skipping patch application"
        echo
    fi
    
    echo "--> Generating Treble device makefiles"
    cd device/phh/treble
    git clean -fdx
    bash generate.sh
    cd ../../..
    echo
}

setupEnv() {
    echo "--> Setting up build environment"
    mkdir -p $OUTPUT_DIR
    source build/envsetup.sh
    echo
    
    # Enable ccache
    export USE_CCACHE=1
    export CCACHE_COMPRESS=1
    export CCACHE_MAXSIZE=50G
    ccache -M 50G -F 0 2>/dev/null || true
    echo
}

buildTrebleApp() {
    echo "--> Building Treble app"
    if [ -d packages/apps/TrebleApp ]; then
        (cd packages/apps/TrebleApp; ./gradlew assembleRelease 2>/dev/null || echo "Treble app build failed")
    else
        echo "TrebleApp not found, skipping"
    fi
    echo
}

buildVariant() {
    echo "--> Building $1"
    lunch "$1"-bp2a-userdebug
    make -j24 installclean
    
    # Check if this is a GApps variant
    if [[ "$1" == *"bg"* ]]; then
        echo "--> Building with GApps"
        make RELAX_USES_LIBRARY_CHECK=true BUILD_NUMBER=$BUILD_NUMBER TARGET_BUILD_GAPPS=true -j24 systemimage
    else
        echo "--> Building Vanilla variant"
        make RELAX_USES_LIBRARY_CHECK=true BUILD_NUMBER=$BUILD_NUMBER -j24 systemimage
    fi
    
    make -j24 vndk-test-sepolicy
    mv $OUT/system.img $OUTPUT_DIR/system-"$1".img
    echo
}

buildVariants() {
    buildVariant treble_arm64_bvN
    buildVariant treble_arm64_bgN
}

generatePackages() {
    echo "--> Generating compressed packages"
    buildDate="$(date +%Y%m%d)"
    find $OUTPUT_DIR/ -name "system-treble_*.img" | while read file; do
        filename="$(basename $file)"
        [[ "$filename" == *"_bvN"* ]] && variant="vanilla" || variant="gapps"
        name="axionos-arm64-ab-${variant}-16.0-$buildDate"
        xz -cv "$file" -T0 > $OUTPUT_DIR/"$name".img.xz
        BUILT_FILES+=("$OUTPUT_DIR/$name.img.xz")
    done
    rm -rf $OUTPUT_DIR/system-*.img
    
    # Save manifest
    repo manifest -r > $OUTPUT_DIR/manifest-$buildDate.xml
    BUILT_FILES+=("$OUTPUT_DIR/manifest-$buildDate.xml")
    echo
}

uploadToGoFile() {
    local file="$1"
    if [ -f "$file" ]; then
        echo "Uploading $file to GoFile..."
        ./upload.sh "$file"
    else
        echo "File $file not found, skipping upload."
    fi
}

selectUploads() {
    echo
    echo "--------------------------------------"
    echo " Select Files to Upload to GoFile"
    echo "--------------------------------------"
    
    # Download GoFile upload script if not present
    if [ ! -f upload.sh ]; then
        echo "Downloading GoFile upload script..."
        wget -q https://raw.githubusercontent.com/Sushrut1101/GoFile-Upload/refs/heads/master/upload.sh && chmod +x upload.sh
    fi
    
    # List all files
    local file_list=()
    find $OUTPUT_DIR/ -name "*.img.xz" -o -name "manifest-*.xml" | sort | while read file; do
        echo "$file"
    done > /tmp/build_files.txt
    
    mapfile -t file_list < /tmp/build_files.txt
    
    for i in "${!file_list[@]}"; do
        file="${file_list[$i]}"
        filename=$(basename "$file")
        filesize=$(du -h "$file" 2>/dev/null | cut -f1 || echo "N/A")
        echo "[$((i+1))] $filename ($filesize)"
    done
    
    echo
    echo "Options:"
    echo "  [a] Upload all files"
    echo "  [n] Upload none (skip upload)"
    echo "  [1-${#file_list[@]}] Upload specific file numbers (space-separated)"
    echo
    read -p "Enter your choice: " choice
    
    case "$choice" in
        a|A)
            echo
            echo "Uploading all files to GoFile..."
            for file in "${file_list[@]}"; do
                uploadToGoFile "$file"
            done
            ;;
        n|N)
            echo
            echo "Skipping upload. Files saved locally in: $OUTPUT_DIR/"
            ;;
        *)
            echo
            echo "Uploading selected files..."
            for num in $choice; do
                if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#file_list[@]}" ]; then
                    uploadToGoFile "${file_list[$((num-1))]}"
                else
                    echo "Invalid selection: $num (skipped)"
                fi
            done
            ;;
    esac
    
    echo
}

# Main execution
START=$(date +%s)

initRepos
syncRepos
applyPatches
setupEnv
buildTrebleApp
buildVariants
generatePackages
selectUploads

END=$(date +%s)
ELAPSEDM=$(($(($END-$START))/60))
ELAPSEDS=$(($(($END-$START))-$ELAPSEDM*60))

echo "--------------------------------------"
echo " Buildbot completed in $ELAPSEDM minutes and $ELAPSEDS seconds"
echo "--------------------------------------"
echo
echo "Output files in: $OUTPUT_DIR/"
echo "--------------------------------------"

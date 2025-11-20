#!/usr/bin/env bash

# AxionOS GSI Build Bot
# Usage: bash ./Build.sh

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROM_NAME="AxionOS"
WORK_DIR="$SCRIPT_DIR"
SOURCE_DIR="$WORK_DIR/axion"
OUTPUT_DIR="$WORK_DIR/output"
TREBLE_DIR="$WORK_DIR/treble"
LOG_FILE="$WORK_DIR/build_$(date +%Y%m%d_%H%M%S).log"

# Build config
BUILD_VARIANT="${BUILD_VARIANT:-va}"
BUILD_THREADS="${BUILD_THREADS:-$(nproc --all)}"
SYNC_THREADS=24

log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

check_dependencies() {
    log "Checking dependencies..."
    local deps=("git" "wget" "curl" "repo" "python3")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            error "$dep is not installed."
        fi
    done
}

setup_dirs() {
    mkdir -p "$WORK_DIR" "$SOURCE_DIR" "$OUTPUT_DIR" "$TREBLE_DIR"
}

setup_gofile() {
    cd "$WORK_DIR"
    if [ ! -f "upload.sh" ]; then
        wget -q https://raw.githubusercontent.com/Sushrut1101/GoFile-Upload/refs/heads/master/upload.sh
        chmod +x upload.sh
    fi
}

init_repo() {
    log "Initializing AxionOS..."
    cd "$SOURCE_DIR"
    if [ ! -d ".repo" ]; then
        repo init -u https://github.com/AxionAOSP/android.git -b lineage-23.0 --git-lfs
    fi
}

sync_sources() {
    log "Syncing source..."
    cd "$SOURCE_DIR"
    repo sync -c -j"$SYNC_THREADS" --force-sync --no-clone-bundle --no-tags
}

clone_treble() {
    log "Cloning Treble repos..."
    cd "$TREBLE_DIR"
    
    if [ -d "patches" ]; then
        info "Patches folder exists, updating..."
        cd patches
        git pull
        cd ..
    else
        info "Cloning patches..."
        git clone https://github.com/Doze-off/patches
    fi

    if [ -d "device_phh_treble" ]; then
        cd device_phh_treble
        git pull
        cd ..
    else
        # Removed explicit directory argument; git will create 'device_phh_treble' automatically
        git clone https://github.com/TrebleDroid/device_phh_treble
    fi
    
    if [ -d "treble_app" ]; then
        cd treble_app
        git pull
        cd ..
    else
        git clone https://github.com/TrebleDroid/treble_app
    fi
}

apply_treble_patches() {
    log "Applying patches..."
    cd "$SOURCE_DIR"
    
    local patch_script="$TREBLE_DIR/patches/apply-patches.sh"
    local patch_dir="$TREBLE_DIR/patches"
    
    if [ -f "$patch_script" ]; then
        bash "$patch_script" "$patch_dir"
    else
        error "apply-patches.sh not found at $patch_script"
    fi
}

add_treble_app() {
    local treble_app_dir="$SOURCE_DIR/vendor/hardware_overlay/TrebleApp"
    mkdir -p "$treble_app_dir"
    cp -r "$TREBLE_DIR/treble_app/"* "$treble_app_dir/"
}

setup_gsi_device() {
    cd "$SOURCE_DIR"
    local device_dir="$SOURCE_DIR/device/phh/treble"
    
    if [ ! -d "$device_dir" ]; then
        mkdir -p "$device_dir"
        if [ -d "$TREBLE_DIR/device_phh_treble" ]; then
            cp -r "$TREBLE_DIR/device_phh_treble/"* "$device_dir/"
        fi
    fi
}

configure_build() {
    cd "$SOURCE_DIR"
    source build/envsetup.sh
    if command -v gk &> /dev/null; then
        gk -s
    fi
}

build_gsi_target() {
    local target=$1
    local variant=$2
    
    log "Building $target ($variant)..."
    cd "$SOURCE_DIR"
    source build/envsetup.sh
    
    axion "$target" "$variant" || lunch "lineage_${target}-userdebug"
    ax -br -j$(nproc --all) 2>&1 | tee -a "$LOG_FILE" || make systemimage -j$(nproc --all) 2>&1 | tee -a "$LOG_FILE"
    
    if [ $? -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

build_gsi() {
    local targets=("treble_arm64_bgN")
    
    for target in "${targets[@]}"; do
        local axion_variant="va"
        if [[ "$target" == *"bg"* ]]; then
            axion_variant="gms core"
        fi
        
        cd "$SOURCE_DIR"
        make installclean || true
        
        if build_gsi_target "$target" "$axion_variant"; then
            local img_name="${ROM_NAME}-${target}-$(date +%Y%m%d).img"
            local system_img=$(find "$SOURCE_DIR/out/target/product" -name "system.img" -o -name "system_ext.img" | head -n1)
            
            if [ -f "$system_img" ]; then
                cp "$system_img" "$OUTPUT_DIR/$img_name"
                cd "$OUTPUT_DIR"
                xz -9 -T$(nproc --all) "$img_name"
                log "Saved: $img_name.xz"
            fi
        fi
    done
}

upload_to_gofile() {
    log "Uploading..."
    cd "$OUTPUT_DIR"
    for file in *.xz; do
        if [ -f "$file" ]; then
            "$WORK_DIR/upload.sh" "$file" | tee -a "$LOG_FILE"
        fi
    done
}

generate_info() {
    cat > "$OUTPUT_DIR/BUILD_INFO.txt" << EOF
AxionOS GSI Build
Date: $(date)
ROM: $ROM_NAME
EOF
}

main() {
    log "=== AxionOS GSI Build Bot ==="
    log "Work Dir: $WORK_DIR"
    
    check_dependencies
    setup_dirs
    setup_gofile
    init_repo
    sync_sources
    clone_treble
    apply_treble_patches
    add_treble_app
    setup_gsi_device
    configure_build
    build_gsi
    generate_info
    upload_to_gofile
    
    log "Done. Output: $OUTPUT_DIR"
}

trap 'error "Failed at line $LINENO"' ERR

main "$@"
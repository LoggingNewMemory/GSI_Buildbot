#!/usr/bin/env bash

# AxionOS GSI Build Bot with Auto Upload
# This script builds GSI with TrebleDroid patches, overlays, and Treble app
# Usage: bash ./Build.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROM_NAME="AxionOS"
WORK_DIR="${WORK_DIR:-$HOME/gsi-build}"
SOURCE_DIR="$WORK_DIR/axion"
OUTPUT_DIR="$WORK_DIR/output"
TREBLE_DIR="$WORK_DIR/treble"
LOG_FILE="$WORK_DIR/build_$(date +%Y%m%d_%H%M%S).log"

# Build configuration
BUILD_VARIANT="${BUILD_VARIANT:-va}"  # va = vanilla, gms core, gms pico
BUILD_THREADS="${BUILD_THREADS:-$(nproc --all)}"
SYNC_THREADS=24

# Functions
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

# Check dependencies
check_dependencies() {
    log "Checking dependencies..."
    
    local deps=("git" "wget" "curl" "repo" "python3")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            error "$dep is not installed. Please install it first."
        fi
    done
    
    info "All dependencies satisfied"
}

# Setup directories
setup_dirs() {
    log "Setting up build directories..."
    mkdir -p "$WORK_DIR" "$SOURCE_DIR" "$OUTPUT_DIR" "$TREBLE_DIR"
}

# Download GoFile upload script
setup_gofile() {
    log "Setting up GoFile uploader..."
    cd "$WORK_DIR"
    
    if [ ! -f "upload.sh" ]; then
        wget -q https://raw.githubusercontent.com/Sushrut1101/GoFile-Upload/refs/heads/master/upload.sh
        chmod +x upload.sh
        info "GoFile uploader downloaded"
    else
        info "GoFile uploader already exists"
    fi
}

# Initialize repo
init_repo() {
    log "Initializing AxionOS repository..."
    cd "$SOURCE_DIR"
    
    if [ ! -d ".repo" ]; then
        repo init -u https://github.com/AxionAOSP/android.git -b lineage-23.0 --git-lfs
        info "Repository initialized"
    else
        info "Repository already initialized"
    fi
}

# Sync sources
sync_sources() {
    log "Syncing source code (Max threads: $SYNC_THREADS)..."
    cd "$SOURCE_DIR"
    
    repo sync -c -j"$SYNC_THREADS" --force-sync --no-clone-bundle --no-tags
    log "Source sync completed"
}

# Clone TrebleDroid patches
clone_treble() {
    log "Cloning TrebleDroid repositories..."
    cd "$TREBLE_DIR"
    
    # Clone treble_experimentations
    if [ ! -d "treble_experimentations" ]; then
        git clone https://github.com/TrebleDroid/treble_experimentations
    else
        cd treble_experimentations
        git pull
        cd ..
    fi
    
    # Clone treble_app
    if [ ! -d "treble_app" ]; then
        git clone https://github.com/TrebleDroid/treble_app
    else
        cd treble_app
        git pull
        cd ..
    fi
    
    log "TrebleDroid repositories cloned"
}

# Apply TrebleDroid patches
apply_treble_patches() {
    log "Applying TrebleDroid patches..."
    cd "$SOURCE_DIR"
    
    # Apply patches from TrebleDroid
    bash "$TREBLE_DIR/treble_experimentations/apply-patches.sh" "$TREBLE_DIR/treble_experimentations"
    
    log "TrebleDroid patches applied successfully"
}

# Add Treble app to vendor
add_treble_app() {
    log "Adding TrebleDroid app to vendor..."
    
    local treble_app_dir="$SOURCE_DIR/vendor/hardware_overlay/TrebleApp"
    mkdir -p "$treble_app_dir"
    
    # Copy treble_app to vendor
    cp -r "$TREBLE_DIR/treble_app/"* "$treble_app_dir/"
    
    info "TrebleDroid app added to vendor"
}

# Setup GSI device tree
setup_gsi_device() {
    log "Setting up GSI device configurations..."
    cd "$SOURCE_DIR"
    
    # Create device tree for GSI builds if needed
    local device_dir="$SOURCE_DIR/device/phh/treble"
    
    if [ ! -d "$device_dir" ]; then
        mkdir -p "$device_dir"
        
        # Link or copy TrebleDroid device tree
        if [ -d "$TREBLE_DIR/treble_experimentations/device/phh/treble" ]; then
            cp -r "$TREBLE_DIR/treble_experimentations/device/phh/treble/"* "$device_dir/"
        fi
    fi
    
    info "GSI device tree configured"
}

# Configure build environment
configure_build() {
    log "Configuring build environment..."
    cd "$SOURCE_DIR"
    
    # Source build environment
    source build/envsetup.sh
    
    # Run AxionOS setup script if available
    if command -v gk &> /dev/null; then
        gk -s
        info "AxionOS environment setup completed"
    fi
    
    info "Build environment configured"
}

# Build GSI for specific target
build_gsi_target() {
    local target=$1
    local variant=$2
    
    log "Building GSI for target: $target with variant: $variant"
    cd "$SOURCE_DIR"
    
    # Source environment
    source build/envsetup.sh
    
    # Use AxionOS build command
    axion "$target" "$variant" || lunch "lineage_${target}-userdebug"
    
    # Build system image
    ax -br -j$(nproc --all) 2>&1 | tee -a "$LOG_FILE" || make systemimage -j$(nproc --all) 2>&1 | tee -a "$LOG_FILE"
    
    if [ $? -eq 0 ]; then
        log "Build completed for $target"
        return 0
    else
        error "Build failed for $target"
        return 1
    fi
}

# Build all GSI variants
build_gsi() {
    log "Starting GSI build process..."
    
    # GSI targets based on TrebleDroid conventions
    local targets=(
        "treble_arm64_bvN"  # ARM64 A/B vanilla
        "treble_arm64_bgN"  # ARM64 A/B GApps
        "treble_a64_bvN"    # ARM32/64 A/B vanilla
        "treble_a64_bgN"    # ARM32/64 A/B GApps
    )
    
    for target in "${targets[@]}"; do
        log "Processing variant: $target"
        
        # Determine variant type
        local axion_variant="va"  # Default to vanilla
        if [[ "$target" == *"bg"* ]]; then
            axion_variant="gms core"
        fi
        
        # Clean previous build
        cd "$SOURCE_DIR"
        make installclean || true
        
        # Build the target
        if build_gsi_target "$target" "$axion_variant"; then
            # Find and copy the built image
            local img_name="${ROM_NAME}-${target}-$(date +%Y%m%d).img"
            local system_img=$(find "$SOURCE_DIR/out/target/product" -name "system.img" -o -name "system_ext.img" | head -n1)
            
            if [ -f "$system_img" ]; then
                cp "$system_img" "$OUTPUT_DIR/$img_name"
                
                # Compress
                info "Compressing $img_name..."
                cd "$OUTPUT_DIR"
                xz -9 -T$(nproc --all) "$img_name"
                
                log "Output saved: $img_name.xz"
            else
                warn "System image not found for $target"
            fi
        fi
    done
}

# Upload to GoFile
upload_to_gofile() {
    log "Uploading builds to GoFile..."
    cd "$OUTPUT_DIR"
    
    for file in *.xz; do
        if [ -f "$file" ]; then
            info "Uploading $file..."
            "$WORK_DIR/upload.sh" "$file" | tee -a "$LOG_FILE"
            
            if [ $? -eq 0 ]; then
                log "Successfully uploaded: $file"
            else
                warn "Failed to upload: $file"
            fi
        fi
    done
}

# Generate build info
generate_info() {
    log "Generating build information..."
    
    cat > "$OUTPUT_DIR/BUILD_INFO.txt" << EOF
AxionOS GSI Build Information
============================
Build Date: $(date)
ROM: $ROM_NAME (LineageOS 23.0 base)
Builder: AxionOS GSI Build Bot

Variants Built:
$(ls -1 "$OUTPUT_DIR"/*.xz 2>/dev/null | xargs -n1 basename || echo "No builds found")

Build Log: $LOG_FILE

TrebleDroid Components:
- Patches: https://github.com/TrebleDroid/treble_experimentations
- App: https://github.com/TrebleDroid/treble_app

Notes:
- All variants include TrebleDroid patches and app
- Built on AxionOS (LineageOS 23.0 base)
- Compressed with XZ for optimal size
- Uploaded to GoFile for easy distribution

Installation:
1. Download the appropriate variant for your device
2. Decompress: xz -d filename.img.xz
3. Flash via fastboot: fastboot flash system filename.img
4. Optional: Flash vbmeta if needed: fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img
5. Reboot and enjoy!

Variant naming:
- arm64 = 64-bit ARM only
- a64 = 32/64-bit ARM
- bvN = A/B partition, vanilla (no GApps)
- bgN = A/B partition, with GApps
EOF

    info "Build info generated"
}

# Main execution
main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════╗"
    echo "║         AxionOS GSI Build Bot with Auto Upload        ║"
    echo "╚════════════════════════════════════════════════════════╝"
    echo ""
    
    log "=== AxionOS GSI Build Bot Started ==="
    log "Script directory: $SCRIPT_DIR"
    log "Working directory: $WORK_DIR"
    log "Build threads: $BUILD_THREADS"
    log "Sync threads: $SYNC_THREADS"
    log "Build variant: $BUILD_VARIANT"
    echo ""
    
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
    
    echo ""
    log "=== Build process completed! ==="
    log "Output directory: $OUTPUT_DIR"
    log "Build log: $LOG_FILE"
    echo ""
    info "Check GoFile links above for download URLs"
    echo ""
}

# Trap errors
trap 'error "Script failed at line $LINENO"' ERR

# Run main function
main "$@"
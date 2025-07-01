#!/bin/bash
# create-win11-vm.sh - Unified Windows 11 on Arm VM creation script
# Covers how to create, download, prepare, and firstboot operations

set -e

# Script version and info
SCRIPT_VERSION="2.0.0"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# Default values
DEFAULT_USERNAME="win11arm"
DEFAULT_PASSWORD="win11arm"
DEFAULT_DISKSIZE=40
DEFAULT_RDP_PORT=3389
DEFAULT_LANGUAGE="English (United States)"

# Utility functions
error() {
    echo "Error: $1" >&2
    exit 1
}

status() {
    echo "$1" >&2
}

# Function to show usage
show_usage() {
    cat << EOF
Windows 11 on Arm VM Management Script v${SCRIPT_VERSION}

Usage: $0 [command] <vm_path> [options]

Commands (optional, defaults to 'all'):
    create      Create VM directory and copy initial files
    download    Download Windows 11 ISO and VirtIO drivers
    prepare     Prepare VM disk and unattended installation
    firstboot   Boot VM for initial Windows installation
    all         Run all steps in sequence (create -> download -> prepare -> firstboot)

Options:
    --username <name>       Windows username (default: ${DEFAULT_USERNAME})
    --password <pass>       Windows password (default: ${DEFAULT_PASSWORD})
    --disksize <size>       Disk size in GB (default: ${DEFAULT_DISKSIZE})
    --rdp-port <port>       RDP port (default: ${DEFAULT_RDP_PORT})
    --language <lang>       Windows language (default: ${DEFAULT_LANGUAGE})
    --vm-mem <size>         VM memory in GB (auto-detected if not specified)
    --help                  Show this help message

Examples:
    $0 ~/win11-vm                                    # Create VM with all defaults
    $0 create /path/to/vm                           # Just create directory
    $0 download /path/to/vm --username MyUser --password MyPass
    $0 all /path/to/vm --disksize 60 --rdp-port 3390
EOF
}

# Function to parse command line arguments
parse_arguments() {
    COMMAND=""
    VM_PATH=""
    USERNAME="$DEFAULT_USERNAME"
    PASSWORD="$DEFAULT_PASSWORD"
    DISKSIZE="$DEFAULT_DISKSIZE"
    RDP_PORT="$DEFAULT_RDP_PORT"
    LANGUAGE="$DEFAULT_LANGUAGE"
    VM_MEM=""
    
    if [ $# -eq 0 ]; then
        show_usage
        exit 1
    fi
    
    # Check if first argument is a valid command or looks like a path
    case "$1" in
        create|download|prepare|firstboot|all|--help)
            COMMAND="$1"
            shift
            ;;
        *)
            # If first argument is not a command, assume it's a path and default to 'all'
            COMMAND="all"
            ;;
    esac
    
    if [ -z "$1" ] && [ "$COMMAND" != "--help" ]; then
        error "VM path is required"
    fi
    
    if [ "$COMMAND" != "--help" ]; then
        # Expand tilde and resolve path, but don't require it to exist yet
        VM_PATH="$1"
        # Expand tilde if present
        if [[ "$VM_PATH" == "~"* ]]; then
            VM_PATH="${HOME}${VM_PATH:1}"
        fi
        # Convert to absolute path if it's relative
        if [[ "$VM_PATH" != /* ]]; then
            VM_PATH="$(pwd)/$VM_PATH"
        fi
        shift
    fi
    
    while [ $# -gt 0 ]; do
        case "$1" in
            --username)
                USERNAME="$2"
                shift 2
                ;;
            --password)
                PASSWORD="$2"
                shift 2
                ;;
            --disksize)
                DISKSIZE="$2"
                shift 2
                ;;
            --rdp-port)
                RDP_PORT="$2"
                shift 2
                ;;
            --language)
                LANGUAGE="$2"
                shift 2
                ;;
            --vm-mem)
                VM_MEM="$2"
                shift 2
                ;;
            --help)
                show_usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                ;;
        esac
    done
    
    # Validate command
    case "$COMMAND" in
        create|download|prepare|firstboot|all|--help)
            ;;
        *)
            error "Invalid command: $COMMAND"
            ;;
    esac
}

# Function to validate VM path and requirements
validate_environment() {
    # Check if VM path is provided for commands that need it
    if [ "$COMMAND" = "--help" ]; then
        return 0
    fi
    
    if [ -z "$VM_PATH" ]; then
        error "VM path is required"
    fi
    
    # Validate numeric arguments
    if ! [[ "$DISKSIZE" =~ ^[0-9]+$ ]] || [ "$DISKSIZE" -lt 20 ]; then
        error "Disk size must be a number >= 20 GB"
    fi
    
    if ! [[ "$RDP_PORT" =~ ^[0-9]+$ ]] || [ "$RDP_PORT" -lt 1024 ] || [ "$RDP_PORT" -gt 65535 ]; then
        error "RDP port must be a number between 1024-65535"
    fi
    
    if [ -n "$VM_MEM" ] && (! [[ "$VM_MEM" =~ ^[0-9]+$ ]] || [ "$VM_MEM" -lt 2 ]); then
        error "VM memory must be a number >= 2 GB"
    fi
}

# Function to get available disk space in bytes
get_space_free() {
    df --output=avail -B 1 "$1" | tail -n 1
}

# Function to unmount with retries
umount_retry() {
    local max_attempts=5
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if sudo umount "$1" 2>/dev/null; then
            return 0
        fi
        echo "Unmount attempt $attempt failed, retrying in 1 second..."
        sleep 1
        attempt=$((attempt+1))
    done
    
    return 1
}

# Function to patch ISO to not require keypress to boot
patch_iso_noprompt() {
    local ISO="$1"
    local match_offset=934748
    local file_length=1720320
    local match
    
    status "Modifying Windows ISO to boot to installer without keypress:"
    echo "  - Searching for efisys_noprompt.bin to extract..."
    
    while read match; do
        local start_offset=$((match-match_offset))
        
        # Check if this is the expected start of file
        if [ "$(dd if="$ISO" skip=$start_offset bs=1 count=16 status=none | base64)" != '6zyQTVNETUYzLjIAAgIBAA==' ]; then
            echo "  - negative match at byte $start_offset"
            continue
        fi
        
        echo "  - positive match at byte $start_offset"
        echo "  - Extracting it..."
        dd if="$ISO" bs=1 skip=$start_offset count="$file_length" of=/tmp/efisys_noprompt.bin status=none
        break
        
    done < <(grep -abo 'cdboot_noprompt\.pdb' "$ISO" | awk -F: '{print $1}')
    
    # Make sure efisys_noprompt.bin was extracted successfully
    if [ ! -f /tmp/efisys_noprompt.bin ]; then
        error "Failed to extract efisys_noprompt.bin from ISO!"
    elif [ "$(sha1sum /tmp/efisys_noprompt.bin | awk '{print $1}')" != '906e019eb371949290df917e73e387f8a18696d7' ]; then
        error "The extracted efisys_noprompt.bin had an unexpected hash sum"
    else
        echo "  - Checksums match! Now searching ISO for sections to replace..."
    fi
    
    # Find and replace efisys.bin with efisys_noprompt.bin
    while read match; do
        start_offset=$((match-match_offset))
        
        # Check if this is the expected start of file
        if [ "$(dd if="$ISO" skip=$start_offset bs=1 count=16 status=none | base64)" != '6zyQTVNETUYzLjIAAgIBAA==' ]; then
            echo "  - negative match at byte $start_offset, continuing to search..."
            continue
        fi
        
        echo "  - positive match at byte $start_offset, replacing the next $file_length bytes..."
        dd if=/tmp/efisys_noprompt.bin of="$ISO" bs=1 seek=$start_offset conv=notrunc status=none
        
    done < <(grep -abo 'cdboot\.pdb' "$ISO" | awk -F: '{print $1}')
    
    rm -f /tmp/efisys_noprompt.bin
    echo "Done"
}

# Function to download VirtIO drivers
download_virtio_drivers() {
    status "Downloading virtio drivers"
    wget -nv --show-progress "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso" -O "${VM_PATH}/virtio-win.iso" || error "Downloading virtio-win.iso failed"
}

# Function to extract VirtIO drivers
extract_virtio_drivers() {
    status "Extracting VirtIO drivers..."
    TMP="$(mktemp -d)"
    sudo mount -r "$VM_PATH/virtio-win.iso" "$TMP" || error "failed to mount virtio-win.iso for extracting files"
    
    # Copy drivers
    IFS=$'\n'
    for dir in $(find "$TMP" -type d -name ARM64 | grep w11); do
        drivername="$(echo "$dir" | awk -F/ '{print $4}')"
        echo "  - $drivername"
        mkdir -p "$VM_PATH/unattended/$drivername"
        if ! cp -rf --no-preserve mode "$dir"/. "$VM_PATH/unattended/$drivername"; then
            umount_retry "$TMP"
            error "Failed to copy $drivername to $VM_PATH/unattended"
        fi
    done
    
    # Copy guest agent and certificates
    mkdir -p "$VM_PATH/unattended/guest-agent"
    cp -f --no-preserve mode "$TMP/guest-agent/qemu-ga-x86_64.msi" "$VM_PATH/unattended/guest-agent"
    cp -rf --no-preserve mode "$TMP/cert" "$VM_PATH/unattended"
    sync
    
    # Unmount virtio ISO
    umount_retry "$TMP" || error "Failed to unmount virtio-win.iso, please report this issue"
    rmdir "$TMP"
    
    # Remove virtio ISO as it's no longer needed
    rm -f "${VM_PATH}/virtio-win.iso"
}

# Function to setup unattended installation files
setup_unattended_files() {
    status "Setting up unattended installation files..."
    
    mkdir -p "$VM_PATH/unattended"
    
    # Copy autounattend.xml and firstlogin.ps1
    cp -f "$SCRIPT_DIR/resources/autounattend.xml" "$VM_PATH/unattended" || error "failed to copy autounattend.xml to unattended folder"
    cp -f "$SCRIPT_DIR/resources/firstlogin.ps1" "$VM_PATH/unattended" || error "failed to copy firstlogin.ps1 to unattended folder"
    
    # Edit autounattend.xml for language settings
    if ! grep -qF "Microsoft-Windows-International-Core-WinPE" "$VM_PATH/unattended/autounattend.xml"; then
        if [ "$LANGUAGE" == "English (United States)" ]; then
            sed -i 's+<settings pass="windowsPE">+<settings pass="windowsPE">\n    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\n      <SetupUILanguage>\n        <UILanguage>en-US</UILanguage>\n      </SetupUILanguage>\n      <InputLocale>0409:00000409</InputLocale>\n      <SystemLocale>en-US</SystemLocale>\n      <UILanguage>en-US</UILanguage>\n      <UserLocale>en-US</UserLocale>\n    </component>+g' "$VM_PATH/unattended/autounattend.xml"
        elif [ "$LANGUAGE" == "English International" ]; then
            sed -i 's+<settings pass="windowsPE">+<settings pass="windowsPE">\n    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\n      <SetupUILanguage>\n        <UILanguage>en-GB</UILanguage>\n      </SetupUILanguage>\n      <InputLocale>0809:00000809</InputLocale>\n      <SystemLocale>en-GB</SystemLocale>\n      <UILanguage>en-GB</UILanguage>\n      <UserLocale>en-GB</UserLocale>\n    </component>+g' "$VM_PATH/unattended/autounattend.xml"
        fi
    fi
    
    # Set username and password in autounattend.xml
    sed -i "s/win11arm/${PASSWORD}/g ; s/Win11ARM/${USERNAME}/g" "$VM_PATH/unattended/autounattend.xml"
    
    extract_virtio_drivers
}

# Function to download Windows 11 for ARM64
download_windows_11arm64() {
    local session_id=""
    local iso_download_page_html=""
    local product_edition_id=""
    local language_skuid_table_json=""
    local sku_id=""
    local iso_download_link_json=""
    local iso_download_link=""
    local url="https://www.microsoft.com/en-us/software-download/windows11arm64"
    local failed_instructions="    Using a web browser, please manually download the Windows 11 ARM64 ISO from: ${url}
    Save the downloaded ISO to: ${VM_PATH}/installer.iso
    Make sure the file is named installer.iso
    Then run this command again."
    
    status "Downloading Windows 11 ARM64 (${LANGUAGE})"
    
    local user_agent="Mozilla/5.0 (X11; Linux x86_64; rv:100.0) Gecko/20100101 Firefox/100.0"
    session_id="$(uuidgen)"
    
    echo "  - Parsing download page: ${url}"
    iso_download_page_html="$(curl --disable --silent --user-agent "$user_agent" --header "Accept:" --max-filesize 1M --fail --proto =https --tlsv1.2 --http1.1 -- "$url")" || \
        error "Failed to scrape the webpage on step 1.\n$failed_instructions"
    
    echo -n "  - Getting Product edition ID: "
    product_edition_id="$(echo "$iso_download_page_html" | grep -Eo '<option value="[0-9]+">Windows' | cut -d '"' -f 2 | head -n 1 | tr -cd '0-9' | head -c 16)"
    echo "$product_edition_id"
    
    echo "  - Permit Session ID: $session_id"
    curl --disable --silent --output /dev/null --user-agent "$user_agent" --header "Accept:" --max-filesize 100K --fail --proto =https --tlsv1.2 --http1.1 -- "https://vlscppe.microsoft.com/tags?org_id=y6jn8c31&session_id=$session_id" || \
        error "Failed to scrape the webpage on step 2.\n$failed_instructions"
    
    local profile="606624d44113"
    
    echo -n "  - Getting language SKU ID: "
    language_skuid_table_json="$(curl --disable -s --fail --max-filesize 100K --proto =https --tlsv1.2 --http1.1 "https://www.microsoft.com/software-download-connector/api/getskuinformationbyproductedition?profile=${profile}&ProductEditionId=${product_edition_id}&SKU=undefined&friendlyFileName=undefined&Locale=en-US&sessionID=${session_id}")" || \
        error "Failed to scrape the webpage on step 3.\n$failed_instructions"
    
    sku_id="$(echo "${language_skuid_table_json}" | jq -r '.Skus[] | select(.LocalizedLanguage=="'"${LANGUAGE}"'" or .Language=="'"${LANGUAGE}"'").Id')"
    echo "$sku_id"
    [ -z "$sku_id" ] && error "Failed to get the sku_id\n$failed_instructions"
    
    echo "  - Getting ISO download link..."
    iso_download_link_json="$(curl --disable -s --fail --referer "$url" "https://www.microsoft.com/software-download-connector/api/GetProductDownloadLinksBySku?profile=${profile}&productEditionId=undefined&SKU=${sku_id}&friendlyFileName=undefined&Locale=en-US&sessionID=${session_id}")"
    
    if ! [ "$iso_download_link_json" ]; then
        error "Microsoft servers gave an empty response to the request for an automated download.\n$failed_instructions"
    fi
    
    if echo "$iso_download_link_json" | grep -q "Sentinel marked this request as rejected."; then
        error "Microsoft blocked the automated download request based on your IP address. Follow the instructions below, or wait an hour and try again to see if your IP has been unblocked.\n$failed_instructions"
    fi
    
    iso_download_link="$(echo "${iso_download_link_json}" | jq -r '.ProductDownloadOptions[].Uri' | grep Arm64)"
    
    if ! [ "$iso_download_link" ]; then
        error "Microsoft servers gave no download link to the request for an automated download. Please manually download this ISO in a web browser: $url"
    fi
    
    echo "  - URL: ${iso_download_link%%\?*}"
    
    # Download ISO
    wget -nv --show-progress "${iso_download_link}" -O "${VM_PATH}/installer.iso" || error "Failed to download Windows 11 installer.iso from Microsoft\n$failed_instructions"
    
    # Verify
    echo -n "  - Verifying download... "
    sha256="$(sha256sum "${VM_PATH}/installer.iso" | awk '{print $1}')"
    echo "Done"
    if echo "$iso_download_page_html" | grep -qiF "$sha256"; then
        echo "  - Verification successful."
    else
        rm -f "${VM_PATH}/installer.iso"
        error "installer.iso seems corrupted after download. Its sha256sum was:\n$sha256\nwhich does not match any on the expected list"
    fi
}

# Command implementations
cmd_create() {
    status "Creating VM directory and initial setup..."
    
    # Create the VM directory if it doesn't exist
    mkdir -p "$VM_PATH" || error "Failed to create VM directory '$VM_PATH'"
    
    # Create a simple config file for reference (optional, since we use command line args)
    cat > "$VM_PATH/vm-config.txt" << EOF
# VM Configuration (for reference)
# Generated by create-win11-vm.sh v${SCRIPT_VERSION}
VM_PATH=$VM_PATH
USERNAME=$USERNAME
PASSWORD=$PASSWORD
DISKSIZE=$DISKSIZE
RDP_PORT=$RDP_PORT
LANGUAGE=$LANGUAGE
VM_MEM=$VM_MEM
CREATED=$(date)
EOF
    
    # Copy connection file if it exists
    if [ -f "$SCRIPT_DIR/resources/connect.remmina" ]; then
        cp -f "$SCRIPT_DIR/resources/connect.remmina" "$VM_PATH/connect.remmina"
    fi
    
    status "VM directory created successfully at: $VM_PATH"
    status "Next step: $0 download $VM_PATH"
}

cmd_download() {
    status "Starting Windows 11 and drivers download..."
    
    # Check if VM directory exists
    if [ ! -d "$VM_PATH" ]; then
        error "VM directory does not exist at $VM_PATH. Run 'create' command first."
    fi
    
    # Check if installer.iso already exists
    if [ -f "$VM_PATH/installer.iso" ]; then
        read -p "installer.iso already exists. Delete it and download a fresh copy? [Y/n] " answer
        [ "$answer" != "n" ] && rm -f "$VM_PATH/installer.iso"
    fi
    
    # Download Windows 11 if needed
    if [ ! -f "$VM_PATH/installer.iso" ]; then
        # Check for sufficient free disk space
        if [ "$(get_space_free "$VM_PATH")" -le $((DISKSIZE*1024*1024*1024)) ]; then
            error "Insufficient free disk space. ${DISKSIZE} GB is needed, but you only have $(($(get_space_free "$VM_PATH")/1024/1024/1024)) GB."
        fi
        
        download_windows_11arm64
        patch_iso_noprompt "$VM_PATH/installer.iso"
    fi
    
    # Download virtio drivers
    download_virtio_drivers
    
    # Setup unattended installation files
    setup_unattended_files
    
    status "Download completed successfully!"
    status "Next step: $0 prepare $VM_PATH"
}

cmd_prepare() {
    status "Preparing VM for first boot..."
    
    # Check if VM directory exists
    if [ ! -d "$VM_PATH" ]; then
        error "VM directory does not exist at $VM_PATH. Run 'create' and 'download' commands first."
    fi
    
    # Check if required files exist
    if [ ! -d "$VM_PATH/unattended" ]; then
        error "Unattended directory not found at $VM_PATH/unattended. Run 'download' command first."
    fi
    
    # Create unattended.iso with drivers and installation files
    status "Making unattended.iso... "
    mkisofs -quiet -l -J -r -allow-lowercase -allow-multidot -o "$VM_PATH/unattended.iso" "$VM_PATH/unattended/" || error "Failed to create unattended.iso"
    status "Done"
    
    # Handle main hard drive creation
    status "Setting up main hard drive disk.qcow2"
    if [ -f "$VM_PATH/disk.qcow2" ]; then
        status "Proceeding will DELETE your VM's main hard drive and start over with a clean install. ($VM_PATH/disk.qcow2 already exists)"
        read -p "Do you want to continue? (Y/n): " answer
        [ "$answer" == "n" ] && error "Exiting as you requested"
    fi
    rm -f "$VM_PATH/disk.qcow2" || error "Failed to delete $VM_PATH/disk.qcow2"
    
    status "Allocating ${DISKSIZE}GB for main install drive... "
    errors="$(qemu-img create -f qcow2 -o cluster_size=2M,nocow=on,preallocation=metadata "$VM_PATH/disk.qcow2" "${DISKSIZE}G" 2>&1)" || error "Failed to create $VM_PATH/disk.qcow2\nErrors:\n$errors"
    status "Done"
    
    status "VM preparation completed successfully!"
    status "Next step: $0 firstboot $VM_PATH"
}

cmd_firstboot() {
    status "Starting VM for Windows installation..."
    
    # Check if VM directory exists
    if [ ! -d "$VM_PATH" ]; then
        error "VM directory does not exist at $VM_PATH. Run previous commands first."
    fi
    
    # Check if required files exist
    if [ ! -f "$VM_PATH/installer.iso" ]; then
        error "Windows ISO not found at $VM_PATH/installer.iso. Run 'download' command first."
    fi
    
    if [ ! -f "$VM_PATH/unattended.iso" ]; then
        error "Unattended installation ISO not found. Run 'prepare' command first."
    fi
    
    if [ ! -f "$VM_PATH/disk.qcow2" ]; then
        error "Disk image not found. Run 'prepare' command first."
    fi
    
    # Check for desktop environment
    if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ]; then
        error "You need a desktop environment to run firstboot"
    fi
    
    # Export PAN_MESA_DEBUG for better graphics performance
    export PAN_MESA_DEBUG=gl3
    
    # Calculate VM memory if not specified - use half of available RAM
    if [ -z "$VM_MEM" ]; then
        total_ram_gb=$(awk '/MemTotal/ {print int($2/1048576)}' /proc/meminfo)
        VM_MEM=$((total_ram_gb / 2))
        # Ensure minimum of 2GB
        if [ "$VM_MEM" -lt 2 ]; then
            VM_MEM=2
        fi
        # Note: Removed 8GB cap to allow full half-system memory allocation
    fi
    
    # Get number of CPU cores - use half of available cores
    total_cores="$(grep -c ^processor /proc/cpuinfo)"
    num_cores=$((total_cores / 2))
    # Ensure minimum of 2 cores
    if [ "$num_cores" -lt 2 ]; then
        num_cores=2
    fi
    
    # Prepare QEMU flags
    local qemu_flags=(
        -M virt,accel=kvm
        -cpu host
        -m ${VM_MEM}G
        -smp $num_cores
        -name "Windows on Arm"
        -pidfile "$VM_PATH/qemu.pid"
        -device ramfb
        -display gtk,grab-on-hover=on,gl=on
        -device qemu-xhci
        -device usb-kbd
        -device usb-tablet
        -device virtio-rng-pci,rng=rng0
        -object rng-random,id=rng0,filename=/dev/urandom
        -netdev user,id=nic
        -device virtio-net-pci,netdev=nic
        -bios /usr/share/qemu-efi-aarch64/QEMU_EFI.fd
        -drive media=cdrom,index=0,file="$VM_PATH/installer.iso",if=none,id=installer,readonly=on
        -device usb-storage,drive=installer
        -drive media=cdrom,index=1,file="$VM_PATH/unattended.iso",if=none,id=unattended,readonly=on
        -device usb-storage,drive=unattended
        -drive media=cdrom,index=2,file="$VM_PATH/unattended.iso",if=none,id=unattended2,readonly=on
        -device usb-storage,drive=unattended2
        -drive file="$VM_PATH/disk.qcow2",if=virtio,aio=threads,cache=none
    )
    
    status "Starting QEMU with ${VM_MEM}GB RAM (${total_ram_gb}GB total) and $num_cores CPU cores (${total_cores} total)"
    status "Windows should install 100% automatically. This will take awhile."
    
    # Run QEMU with these flags
    if qemu-system-aarch64 "${qemu_flags[@]}"; then
        status "QEMU closed successfully."
        status "Windows installation should be complete!"
        status "You can now use: ./run-win11-vm.sh $VM_PATH"
    else
        local exitcode=$?
        case $exitcode in
            1)
                error "QEMU exited with code 1. This usually means an error occurred during execution."
                ;;
            2)
                error "QEMU exited with code 2. This may indicate an I/O error."
                ;;
            3)
                error "QEMU exited with code 3. This may indicate a bad configuration."
                ;;
            *)
                error "QEMU exited with code $exitcode. Please check the output for errors."
                ;;
        esac
    fi
}

# Main execution starts here
main() {
    parse_arguments "$@"
    validate_environment
    
    case "$COMMAND" in
        --help)
            show_usage
            ;;
        create)
            cmd_create
            ;;
        download)
            cmd_download
            ;;
        prepare)
            cmd_prepare
            ;;
        firstboot)
            cmd_firstboot
            ;;
        all)
            cmd_create
            cmd_download
            cmd_prepare
            cmd_firstboot
            ;;
    esac
}

# Run main function if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi

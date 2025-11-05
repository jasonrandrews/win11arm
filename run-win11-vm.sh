#!/bin/bash
# run-win11-vm.sh - Unified VM launcher that boots VM and connects via RDP seamlessly

set -e

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
VM Launcher - Boot Windows VM and connect via RDP

Usage: $0 <vm_path> [options]

Options:
    --fullscreen    Connect in fullscreen mode
    --rdp-port      RDP port (default: 3389, or from vm-config.txt)
    --help          Show this help message

Examples:
    $0 /path/to/vm                    # Boot VM and connect via RDP
    $0 /path/to/vm --fullscreen       # Boot VM and connect in fullscreen
    $0 /path/to/vm --rdp-port 3390    # Use custom RDP port

This script will:
1. Check if VM is already running
2. Start VM in headless mode if not running
3. Wait for RDP service to be available
4. Connect via RDP using Remmina
EOF
}

# Function to check if process exists
process_exists() {
    [ -n "$1" ] && ps -p "$1" &>/dev/null
}

# Function to check if RDP is available
check_rdp_available() {
    local port="$1"
    timeout 3 bash -c "echo >/dev/tcp/localhost/$port" 2>/dev/null
}

# Function to wait for RDP service
wait_for_rdp() {
    local port="$1"
    local max_attempts=60
    local attempt=1
    
    status "Waiting for RDP service on port $port..."
    
    while [ $attempt -le $max_attempts ]; do
        if check_rdp_available "$port"; then
            status "RDP service is available!"
            return 0
        fi
        
        if [ $((attempt % 10)) -eq 0 ]; then
            status "Still waiting for RDP... (attempt $attempt/$max_attempts)"
        fi
        
        sleep 2
        attempt=$((attempt + 1))
    done
    
    error "RDP service did not become available after $((max_attempts * 2)) seconds"
}

# Function to start VM
start_vm() {
    local vm_path="$1"
    local rdp_port="$2"
    
    status "Starting Windows VM in headless mode..."
    
    # Calculate memory and CPU allocation
    local total_ram_gb=$(awk '/MemTotal/ {print int($2/1048576)}' /proc/meminfo)
    local total_cores=$(grep -c ^processor /proc/cpuinfo)
    local vm_mem
    local num_cores
    if [ "$total_cores" -gt 16 ]; then
        vm_mem=16
        num_cores=8
    else
        vm_mem=$((total_ram_gb / 2))
        [ "$vm_mem" -lt 4 ] && vm_mem=4
        num_cores=$((total_cores / 2))
        [ "$num_cores" -lt 2 ] && num_cores=2
    fi
    status "Using ${vm_mem}GB RAM and $num_cores CPU cores"
    
    # QEMU command
    qemu-system-aarch64 \
        -M virt,accel=kvm \
        -cpu host \
        -m ${vm_mem}G \
        -smp $num_cores \
        -name "Windows on Arm" \
        -pidfile "$vm_path/qemu.pid" \
        -device virtio-balloon \
        -vga none \
        -device virtio-gpu-pci \
        -display none \
        -device qemu-xhci \
        -device usb-kbd \
        -device usb-tablet \
        -device virtio-rng-pci,rng=rng0 \
        -object rng-random,id=rng0,filename=/dev/urandom \
        -netdev user,id=nic,hostfwd=tcp:127.0.0.1:${rdp_port}-:3389 \
        -device virtio-net-pci,netdev=nic \
        -bios /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
        -drive file="$vm_path/disk.qcow2",if=virtio,discard=unmap,aio=threads,cache=none \
        -daemonize
    
    status "VM started successfully"
}

# Function to clean up certificate cache
cleanup_certificates() {
    local rdp_port="$1"
    
    # Remove any cached certificates that might cause issues
    local cert_files=(
        "$HOME/.config/freerdp/server/127.0.0.1_${rdp_port}.pem"
        "$HOME/.config/freerdp/known_hosts2"
        "$HOME/.local/share/remmina/remmina.pref"
    )
    
    for cert_file in "${cert_files[@]}"; do
        if [ -f "$cert_file" ]; then
            status "Cleaning up certificate cache: $(basename "$cert_file")"
            rm -f "$cert_file"
        fi
    done
}

# Function to connect via RDP
connect_rdp() {
    local vm_path="$1"
    local rdp_port="$2"
    local fullscreen="$3"
    
    # Check if Remmina is installed
    if ! command -v remmina &> /dev/null; then
        status "Remmina not found. Installing..."
        sudo apt update && sudo apt install -y remmina remmina-plugin-rdp || error "Failed to install Remmina"
    fi
    
    # Clean up any certificate cache issues
    cleanup_certificates "$rdp_port"
    
    # Get credentials from vm-config.txt if it exists
    local username="win11arm"
    local password="win11arm"
    
    if [ -f "$vm_path/vm-config.txt" ]; then
        username=$(grep "^USERNAME=" "$vm_path/vm-config.txt" 2>/dev/null | cut -d'=' -f2 || echo "Win11ARM")
        password=$(grep "^PASSWORD=" "$vm_path/vm-config.txt" 2>/dev/null | cut -d'=' -f2 || echo "win11arm")
    fi
    
    # Create temporary Remmina profile with proper certificate handling
    local remmina_file="$vm_path/temp-connect.remmina"
    cat > "$remmina_file" << EOF
[remmina]
password=$password
username=$username
domain=
resolution_mode=1
group=
server=127.0.0.1:$rdp_port
colordepth=32
resolution_width=1024
resolution_height=768
name=Windows VM
protocol=RDP
window_maximize=1
viewmode=1
quality=9
sound=local
scale=2
disable_fastpath=0
glyph-cache=0
multitransport=0
relax-order-checks=1
ignore-tls-errors=1
cert_ignore=1
disableautoreconnect=1
network=lan
EOF
    
    # Set fullscreen options
    local remmina_flags="--no-tray-icon"
    if [ "$fullscreen" = true ]; then
        remmina_flags="$remmina_flags --kiosk"
    fi
    
    status "Connecting to VM via RDP (localhost:$rdp_port)..."
    status "Username: $username"
    
    # Set environment variables to help with stability
    export G_SLICE=always-malloc
    export MALLOC_CHECK_=0
    
    # Connect via RDP (suppress crash on exit)
    remmina -c "$remmina_file" $remmina_flags 2>/dev/null || true
    
    # Clean up temporary file
    rm -f "$remmina_file"
}

# Main function
main() {
    local vm_path=""
    local fullscreen=false
    local rdp_port=""
    
    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --help)
                show_usage
                exit 0
                ;;
            --fullscreen)
                fullscreen=true
                shift
                ;;
            --rdp-port)
                rdp_port="$2"
                shift 2
                ;;
            -*)
                error "Unknown option: $1"
                ;;
            *)
                if [ -z "$vm_path" ]; then
                    vm_path="$1"
                else
                    error "Multiple VM paths specified"
                fi
                shift
                ;;
        esac
    done
    
    # Validate arguments
    if [ -z "$vm_path" ]; then
        error "VM path is required. Use --help for usage information."
    fi
    
    vm_path="$(readlink -f "$vm_path")"
    
    if [ ! -d "$vm_path" ]; then
        error "VM directory does not exist: $vm_path"
    fi
    
    if [ ! -f "$vm_path/disk.qcow2" ]; then
        error "VM disk not found: $vm_path/disk.qcow2"
    fi
    
    # Get RDP port from config if not specified
    if [ -z "$rdp_port" ]; then
        if [ -f "$vm_path/vm-config.txt" ]; then
            rdp_port=$(grep "^RDP_PORT=" "$vm_path/vm-config.txt" 2>/dev/null | cut -d'=' -f2 || echo "3389")
        else
            rdp_port="3389"
        fi
    fi
    
    # Validate RDP port
    if ! [[ "$rdp_port" =~ ^[0-9]+$ ]] || [ "$rdp_port" -lt 1024 ] || [ "$rdp_port" -gt 65535 ]; then
        error "Invalid RDP port: $rdp_port (must be 1024-65535)"
    fi
    
    # Check if VM is already running
    local vm_running=false
    if [ -f "$vm_path/qemu.pid" ]; then
        local vm_pid=$(cat "$vm_path/qemu.pid" 2>/dev/null)
        if process_exists "$vm_pid"; then
            vm_running=true
            status "VM is already running (PID: $vm_pid)"
        else
            # Clean up stale PID file
            rm -f "$vm_path/qemu.pid"
        fi
    fi
    
    # Start VM if not running
    if [ "$vm_running" = false ]; then
        start_vm "$vm_path" "$rdp_port"
    fi
    
    # Wait for RDP service
    wait_for_rdp "$rdp_port"
    
    # Connect via RDP
    connect_rdp "$vm_path" "$rdp_port" "$fullscreen"
    
    status "RDP session ended"
}

# Run main function
main "$@"

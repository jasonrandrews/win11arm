# Windows 11 on Arm VM

If you have an Arm Linux machine with KVM support, you can run Windows 11 on Arm using QEMU.

The screenshot below is from the System76 Thelio Astra running Ubuntu 25.04 and a Windows 11 on Arm VM with 32 vCPUs and 30 GB RAM.

![Windows 11 on Arm VM](win11arm.png) 

## Checking for KVM Support

If you are unsure whether your system supports KVM, you can check by running `kvm-ok`. If you see output like:

```
INFO: /dev/kvm exists
KVM acceleration can be used
```

then your system supports KVM and you are ready to proceed.

If you don't have `kvm-ok`, install it on Debian-based Linux distributions using:

```
sudo apt install cpu-checker -y
```

## Key Features

- **Single setup script**: All functionality to create a VM from scratch is provided in `create-win11-vm.sh`.
- **Unified VM launcher**: Boot and connect to the VM with a single command using `run-win11-vm.sh`.
- **Command-line arguments**: All settings can be changed via CLI arguments.
- **Flexible execution**: Run individual VM creation steps or all steps at once.

## Setup Usage

You must provide a path to store the VM's artifacts. Substitute this path for `/path/to/vm` in the commands below. For example, you can use `$HOME/win11-vm`.

### Quick Start (All Steps)

To run all steps to create a new Windows 11 on Arm VM:

```bash
./create-win11-vm.sh all $HOME/win11-vm
```

You can change the VM path and specify other options:

```bash
./create-win11-vm.sh all /path/to/vm --username MyUser --password MyPass
```

### Step by Step

To run individual steps:

```bash
# 1. Create VM directory
./create-win11-vm.sh create /path/to/vm

# 2. Download Windows 11 and drivers
./create-win11-vm.sh download /path/to/vm --username MyUser --password MyPass

# 3. Prepare VM disk and installation
./create-win11-vm.sh prepare /path/to/vm

# 4. Boot VM for Windows installation
./create-win11-vm.sh firstboot /path/to/vm
```

### Available Options
- `--username <name>` - Windows username (default: win11arm)
- `--password <pass>` - Windows password (default: win11arm)
- `--disksize <size>` - Disk size in GB (default: 40)
- `--rdp-port <port>` - RDP port (default: 3389)
- `--language <lang>` - Windows language (default: English (United States))
- `--vm-mem <size>` - VM memory in GB (auto-detected if not specified)

### Examples

Here are more examples:

```bash
# Create VM with custom settings
./create-win11-vm.sh all /home/user/my-vm --disksize 60 --rdp-port 3390 --username Admin

# Download with different language
./create-win11-vm.sh download /path/to/vm --language "English International"

# Get help
./create-win11-vm.sh --help
```

## Running Your VM

After the Windows installation is complete, use the script to run the VM:

```bash
./run-win11-vm.sh $HOME/win11-vm
```

Other examples:

```bash
# Boot VM and connect via RDP in one command
./run-win11-vm.sh /path/to/vm

# Connect in fullscreen mode
./run-win11-vm.sh /path/to/vm --fullscreen

# Use custom RDP port
./run-win11-vm.sh /path/to/vm --rdp-port 3390

# Get help
./run-win11-vm.sh --help
```

The `run-win11-vm.sh` script will:
1. Check if the VM is already running
2. Start the VM in headless mode if not running
3. Wait for the RDP service to be available
4. Connect via RDP using Remmina

## Shut Down the VM

To shut down your Windows 11 VM:

1. **From within Windows**: Use the standard Windows shutdown process (Start menu → Power → Shut down)
2. **Automatic cleanup**: When Windows shuts down, the VM will automatically stop and Remmina will exit.

## Avoid downloading the Windows ISO

If you already have a Windows 11 installer ISO, you can copy it to your VM directory as `installer.iso` before running the setup script. When you run `create-win11-vm.sh`, the script will detect the existing `installer.iso` and ask if you want to use it or download a fresh copy. Choosing to use the existing ISO will save time by avoiding another download.

## Hardware resources

When creating and running your Windows 11 on Arm VM, the scripts automatically detect your system's available CPU cores and RAM.

When you launch the VM, the script will use half of your available CPU cores (with a minimum of 4) and half of your available RAM (with a minimum of 2GB and a maximum of 8GB) by default. You can override the memory allocation using the `--vm-mem` option if needed.

This approach ensures the VM runs efficiently without consuming all system resources, but you can adjust these settings to fit your needs.

## Default disk size

By default, the VM disk size is set to 40GB when you create a new Windows 11 VM using `create-win11-vm.sh`. If you want to use a different disk size, you can specify it with the `--disksize` option (in gigabytes). For example, to create a 60GB disk, use:

```bash
./create-win11-vm.sh all /path/to/vm --disksize 60
```

You can set the disk size during any step that creates or prepares the VM disk. If not specified, the script will use the default of 40GB.

## Dependencies

Required packages:
- `qemu-system-aarch64`
- `qemu-img`
- `mkisofs`
- `wget`
- `curl`
- `jq`
- `uuidgen`
- `remmina` (automatically installed by run-win11-vm.sh if needed)

## Known Issues

### Remmina Crash on Exit

When disconnecting from the RDP session, Remmina may crash with an "Aborted (core dumped)" error:

```
./run-win11-vm.sh: line 143: 60433 Aborted                 (core dumped) remmina -c "$remmina_file" $remmina_flags 2> /dev/null
RDP session ended
```

This is a known issue with Remmina and does not affect VM functionality. The VM continues running normally after the RDP client crashes. You can safely ignore this error message. It does not impact the Windows 11 VM operation.

## Acknowledgements

This project was inspired by Botspot Virtual Machine (BVM) on the Raspberry Pi. For more information visit the project at 
https://github.com/Botspot/bvm

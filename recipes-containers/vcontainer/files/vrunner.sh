#!/bin/bash
# SPDX-FileCopyrightText: Copyright (C) 2025 Bruce Ashfield
#
# SPDX-License-Identifier: GPL-2.0-only
#
# vrunner.sh
# Core runner for vdkr/vpdmn: execute container commands in QEMU-emulated environment
#
# This script is runtime-agnostic and supports both Docker and Podman via --runtime.
#
# Boot flow:
# 1. QEMU loads kernel + tiny initramfs (busybox + preinit)
# 2. preinit mounts rootfs.img (/dev/vda) and does switch_root
# 3. Real /init runs on actual ext4 filesystem
# 4. Container runtime starts, executes command, outputs results
#
# This two-stage boot is required because runc needs pivot_root,
# which doesn't work from initramfs (rootfs isn't a mount point).
#
# Drive layout:
#   /dev/vda = rootfs.img (ro, ext4 with container tools)
#   /dev/vdb = input disk (optional, user data)
#   /dev/vdc = state disk (optional, persistent container storage)
#
# Version: 3.4.0

set -e

VERSION="3.4.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Runtime selection: docker or podman
# This affects blob directory, cmdline prefix, state directory, and log prefix
RUNTIME="${VRUNNER_RUNTIME:-docker}"

# Configuration
TARGET_ARCH="${VDKR_ARCH:-${VPDMN_ARCH:-aarch64}}"
TIMEOUT="${VDKR_TIMEOUT:-${VPDMN_TIMEOUT:-300}}"
VERBOSE="${VDKR_VERBOSE:-${VPDMN_VERBOSE:-false}}"

# Runtime-specific settings (set after parsing --runtime)
set_runtime_config() {
    case "$RUNTIME" in
        docker)
            TOOL_NAME="vdkr"
            BLOB_SUBDIR="vdkr-blobs"
            BLOB_SUBDIR_ALT="blobs"
            CMDLINE_PREFIX="docker"
            STATE_DIR_BASE="${VDKR_STATE_DIR:-$HOME/.vdkr}"
            STATE_FILE="docker-state.img"
            ;;
        podman)
            TOOL_NAME="vpdmn"
            BLOB_SUBDIR="vpdmn-blobs"
            BLOB_SUBDIR_ALT="blobs/vpdmn"
            CMDLINE_PREFIX="podman"
            STATE_DIR_BASE="${VPDMN_STATE_DIR:-$HOME/.vpdmn}"
            STATE_FILE="podman-state.img"
            ;;
        *)
            echo "ERROR: Unknown runtime: $RUNTIME (use docker or podman)" >&2
            exit 1
            ;;
    esac
}

# Blob locations - relative to script for relocatable installation
# Determined after runtime is set
# Note: If BLOB_DIR was set via --blob-dir argument, don't override it
set_blob_dir() {
    # Skip if already set by command line argument
    if [ -n "$BLOB_DIR" ]; then
        return
    fi
    if [ -n "${VDKR_BLOB_DIR:-${VPDMN_BLOB_DIR:-}}" ]; then
        BLOB_DIR="${VDKR_BLOB_DIR:-${VPDMN_BLOB_DIR}}"
    elif [ -d "$SCRIPT_DIR/$BLOB_SUBDIR" ]; then
        BLOB_DIR="$SCRIPT_DIR/$BLOB_SUBDIR"
    elif [ -d "$SCRIPT_DIR/$BLOB_SUBDIR_ALT" ]; then
        BLOB_DIR="$SCRIPT_DIR/$BLOB_SUBDIR_ALT"
    else
        BLOB_DIR="$SCRIPT_DIR/$BLOB_SUBDIR"
    fi
}

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

log() {
    local level="$1"
    local message="$2"
    local prefix="[${TOOL_NAME:-vdkr}]"
    case "$level" in
        "INFO")  [ "$VERBOSE" = "true" ] && echo -e "${GREEN}${prefix}${NC} $message" >&2 || true ;;
        "WARN")  echo -e "${YELLOW}${prefix}${NC} $message" >&2 ;;
        "ERROR") echo -e "${RED}${prefix}${NC} $message" >&2 ;;
        "DEBUG") [ "$VERBOSE" = "true" ] && echo -e "${BLUE}${prefix}${NC} $message" >&2 || true ;;
    esac
}

# ============================================================================
# Multi-Architecture OCI Support for Batch Import
# ============================================================================

# Normalize architecture name to OCI convention
normalize_arch_to_oci() {
    local arch="$1"
    case "$arch" in
        aarch64) echo "arm64" ;;
        x86_64)  echo "amd64" ;;
        *)       echo "$arch" ;;
    esac
}

# Check if OCI directory contains a multi-architecture Image Index
is_oci_image_index() {
    local oci_dir="$1"
    [ -f "$oci_dir/index.json" ] || return 1
    grep -q '"platform"' "$oci_dir/index.json" 2>/dev/null
}

# Get list of available platforms in a multi-arch OCI Image Index
get_oci_platforms() {
    local oci_dir="$1"
    [ -f "$oci_dir/index.json" ] || return 1
    grep -o '"architecture"[[:space:]]*:[[:space:]]*"[^"]*"' "$oci_dir/index.json" 2>/dev/null | \
        sed 's/.*"\([^"]*\)"$/\1/' | tr '\n' ' ' | sed 's/ $//'
}

# Select manifest digest for a specific platform from OCI Image Index
# Returns the sha256 digest (without prefix)
select_platform_manifest() {
    local oci_dir="$1"
    local target_arch="$2"
    local oci_arch=$(normalize_arch_to_oci "$target_arch")

    [ -f "$oci_dir/index.json" ] || return 1

    local in_manifest=0 current_digest="" current_arch="" matched_digest=""

    while IFS= read -r line; do
        if echo "$line" | grep -q '"manifests"'; then
            in_manifest=1
            continue
        fi
        if [ "$in_manifest" = "1" ]; then
            if echo "$line" | grep -q '"digest"'; then
                current_digest=$(echo "$line" | sed 's/.*"sha256:\([a-f0-9]*\)".*/\1/')
            fi
            # Handle both: "architecture": "arm64" or {"architecture": "arm64", ...}
            if echo "$line" | grep -q '"architecture"'; then
                current_arch=$(echo "$line" | sed 's/.*"architecture"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
                if [ "$current_arch" = "$oci_arch" ]; then
                    matched_digest="$current_digest"
                    break
                fi
            fi
            if echo "$line" | grep -q '^[[:space:]]*}'; then
                current_digest=""
                current_arch=""
            fi
        fi
    done < "$oci_dir/index.json"

    [ -n "$matched_digest" ] && echo "$matched_digest"
}

# Extract a single platform from multi-arch OCI to a new OCI directory
extract_platform_oci() {
    local src_dir="$1"
    local dest_dir="$2"
    local manifest_digest="$3"

    mkdir -p "$dest_dir/blobs/sha256"
    cp "$src_dir/blobs/sha256/$manifest_digest" "$dest_dir/blobs/sha256/"

    local manifest_file="$src_dir/blobs/sha256/$manifest_digest"

    # Copy config blob
    local config_digest=$(grep -o '"config"[[:space:]]*:[[:space:]]*{[^}]*"digest"[[:space:]]*:[[:space:]]*"sha256:[a-f0-9]*"' "$manifest_file" | \
        sed 's/.*sha256:\([a-f0-9]*\)".*/\1/')
    [ -n "$config_digest" ] && [ -f "$src_dir/blobs/sha256/$config_digest" ] && \
        cp "$src_dir/blobs/sha256/$config_digest" "$dest_dir/blobs/sha256/"

    # Copy layer blobs
    grep -o '"digest"[[:space:]]*:[[:space:]]*"sha256:[a-f0-9]*"' "$manifest_file" | \
        sed 's/.*sha256:\([a-f0-9]*\)".*/\1/' | while read -r layer_digest; do
        [ -f "$src_dir/blobs/sha256/$layer_digest" ] && \
            cp "$src_dir/blobs/sha256/$layer_digest" "$dest_dir/blobs/sha256/"
    done

    local manifest_size=$(stat -c%s "$manifest_file" 2>/dev/null || stat -f%z "$manifest_file" 2>/dev/null)

    cat > "$dest_dir/index.json" << EOF
{
  "schemaVersion": 2,
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:$manifest_digest",
      "size": $manifest_size
    }
  ]
}
EOF

    [ -f "$src_dir/oci-layout" ] && cp "$src_dir/oci-layout" "$dest_dir/" || \
        echo '{"imageLayoutVersion": "1.0.0"}' > "$dest_dir/oci-layout"
}

show_usage() {
    cat << 'EOF'
vrunner.sh - Execute docker commands in QEMU-emulated environment

USAGE:
    vrunner.sh [OPTIONS] -- <docker-command> [args...]

OPTIONS:
    --arch <arch>        Target architecture (aarch64, x86_64) [default: aarch64]
    --input <path>       Input file/directory for docker command (mounted as {INPUT})
    --input-type <type>  Input type: none, oci, tar, dir [default: auto-detect]
    --input-storage <tar> Restore Docker state from tar before running command
    --state-dir <path>   Use persistent directory for Docker storage between runs
    --output-type <type> Output type: text, tar, storage [default: text]
    --output <path>      Output file for tar/storage output types
    --blob-dir <path>    Directory containing kernel/initramfs blobs
    --network, -n        Enable networking (slirp user-mode, outbound only)
    --registry <url>     Default registry for unqualified images (e.g., 10.0.2.2:5000/yocto)
    --insecure-registry <host:port>  Mark registry as insecure (HTTP). Can repeat.
    --interactive, -it   Run in interactive mode (connects terminal to container)
    --timeout <secs>     QEMU timeout [default: 300]
    --idle-timeout <s>   Daemon idle timeout in seconds [default: 1800]
    --no-kvm             Disable KVM acceleration (use TCG emulation)
    --no-daemon          Placeholder for CLI wrapper (ignored by vrunner)
    --batch-import       Batch import mode: import multiple OCI containers in one session
    --keep-temp          Keep temporary files for debugging
    --verbose, -v        Enable verbose output
    --help, -h           Show this help

INPUT TYPES:
    none    No input data (docker commands that don't need files)
    oci     OCI container directory (has index.json, blobs/)
    tar     Tar archive (docker save output, etc.)
    dir     Generic directory

OUTPUT TYPES:
    text    Capture command stdout/stderr as text (default)
    tar     Expect command to create /tmp/output.tar, return as file
    storage Export entire /var/lib/docker as tar

PLACEHOLDERS:
    {INPUT}  Replaced with path to mounted input inside QEMU

EXAMPLES:
    # List images (no input needed)
    vrunner.sh -- docker images

    # Load an image from tar
    vrunner.sh --input myimage.tar -- docker load -i {INPUT}

    # Import an OCI container
    vrunner.sh --input ./container-oci/ --input-type oci \
        -- docker import {INPUT}/blobs/sha256/LARGEST myimage:latest

    # Save an image to tar (after loading)
    vrunner.sh --input myimage.tar --output-type tar \
        -- 'docker load -i {INPUT} && docker save -o /tmp/output.tar myimage:latest'

    # Get full docker storage after operations
    vrunner.sh --input myimage.tar --output-type storage --output storage.tar \
        -- docker load -i {INPUT}

    # Pull an image from a registry (requires --network)
    vrunner.sh --network -- docker pull alpine:latest

    # Pull from local registry using default registry prefix
    vrunner.sh --network --registry 10.0.2.2:5000/yocto \
        -- docker pull container-base
    # This becomes: docker pull 10.0.2.2:5000/yocto/container-base

    # Batch import multiple OCI containers in one session
    vrunner.sh --batch-import --output storage.tar \
        -- /path/to/app-oci:myapp:latest /path/to/db-oci:mydb:v1.0

    # Batch import with existing storage (additive)
    vrunner.sh --batch-import --input-storage existing.tar --output merged.tar \
        -- /path/to/new-oci:newapp:latest

EOF
}

# Parse arguments
INPUT_PATH=""
INPUT_TYPE="none"
NETWORK="false"
INTERACTIVE="false"
INPUT_STORAGE=""
STATE_DIR=""
OUTPUT_TYPE="text"
OUTPUT_FILE=""
KEEP_TEMP="false"
DISABLE_KVM="false"
DOCKER_CMD=""
PORT_FORWARDS=()

# Registry configuration
DOCKER_REGISTRY=""
INSECURE_REGISTRIES=()
SECURE_REGISTRY="false"
CA_CERT=""
REGISTRY_USER=""
REGISTRY_PASS=""

# Batch import mode
BATCH_IMPORT="false"

# Daemon mode options
DAEMON_MODE=""          # start, send, stop, status
DAEMON_SOCKET_DIR=""    # Directory for daemon socket/PID files
IDLE_TIMEOUT="1800"     # Default: 30 minutes

while [ $# -gt 0 ]; do
    case $1 in
        --runtime)
            RUNTIME="$2"
            shift 2
            ;;
        --arch)
            TARGET_ARCH="$2"
            shift 2
            ;;
        --input)
            INPUT_PATH="$2"
            shift 2
            ;;
        --input-type)
            INPUT_TYPE="$2"
            shift 2
            ;;
        --input-storage)
            INPUT_STORAGE="$2"
            shift 2
            ;;
        --state-dir)
            STATE_DIR="$2"
            shift 2
            ;;
        --output-type)
            OUTPUT_TYPE="$2"
            shift 2
            ;;
        --output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --blob-dir)
            BLOB_DIR="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --network|-n)
            NETWORK="true"
            shift
            ;;
        --port-forward)
            # Format: host_port:container_port or host_port:container_port/protocol
            PORT_FORWARDS+=("$2")
            shift 2
            ;;
        --registry)
            # Default registry for unqualified images (e.g., 10.0.2.2:5000/yocto)
            DOCKER_REGISTRY="$2"
            shift 2
            ;;
        --insecure-registry)
            # Mark a registry as insecure (HTTP)
            INSECURE_REGISTRIES+=("$2")
            shift 2
            ;;
        --secure-registry)
            # Enable TLS verification for registry
            SECURE_REGISTRY="true"
            shift
            ;;
        --ca-cert)
            # Path to CA certificate for TLS verification
            CA_CERT="$2"
            shift 2
            ;;
        --registry-user)
            # Registry username
            REGISTRY_USER="$2"
            shift 2
            ;;
        --registry-pass)
            # Registry password
            REGISTRY_PASS="$2"
            shift 2
            ;;
        --interactive|-it)
            INTERACTIVE="true"
            shift
            ;;
        --keep-temp)
            KEEP_TEMP="true"
            shift
            ;;
        --no-kvm)
            DISABLE_KVM="true"
            shift
            ;;
        --batch-import)
            BATCH_IMPORT="true"
            # Force storage output type for batch import
            OUTPUT_TYPE="storage"
            shift
            ;;
        --daemon-start)
            DAEMON_MODE="start"
            shift
            ;;
        --daemon-send)
            DAEMON_MODE="send"
            shift
            ;;
        --daemon-send-input)
            DAEMON_MODE="send-input"
            shift
            ;;
        --daemon-interactive)
            DAEMON_MODE="interactive"
            shift
            ;;
        --daemon-stop)
            DAEMON_MODE="stop"
            shift
            ;;
        --daemon-status)
            DAEMON_MODE="status"
            shift
            ;;
        --daemon-socket-dir)
            DAEMON_SOCKET_DIR="$2"
            shift 2
            ;;
        --idle-timeout)
            IDLE_TIMEOUT="$2"
            shift 2
            ;;
        --no-daemon)
            # Placeholder for CLI wrapper - vrunner.sh itself doesn't use this
            # but we accept it so callers can pass it through
            shift
            ;;
        --verbose|-v)
            VERBOSE="true"
            shift
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        --)
            shift
            DOCKER_CMD="$*"
            break
            ;;
        *)
            # If we hit a non-option, assume rest is docker command
            DOCKER_CMD="$*"
            break
            ;;
    esac
done

# Initialize runtime-specific configuration
set_runtime_config
set_blob_dir

# Daemon mode handling
# Set default socket directory based on architecture
# If --state-dir was provided, use it for daemon files too
if [ -z "$DAEMON_SOCKET_DIR" ]; then
    if [ -n "$STATE_DIR" ]; then
        DAEMON_SOCKET_DIR="$STATE_DIR"
    else
        DAEMON_SOCKET_DIR="${STATE_DIR_BASE}/${TARGET_ARCH}"
    fi
fi
DAEMON_PID_FILE="$DAEMON_SOCKET_DIR/daemon.pid"
DAEMON_SOCKET="$DAEMON_SOCKET_DIR/daemon.sock"
DAEMON_QEMU_LOG="$DAEMON_SOCKET_DIR/qemu.log"
DAEMON_INPUT_IMG="$DAEMON_SOCKET_DIR/daemon-input.img"
DAEMON_INPUT_SIZE_MB=2048  # 2GB input disk for daemon mode

# Daemon helper functions
daemon_is_running() {
    if [ -f "$DAEMON_PID_FILE" ]; then
        local pid=$(cat "$DAEMON_PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

daemon_status() {
    if daemon_is_running; then
        local pid=$(cat "$DAEMON_PID_FILE")
        echo "Daemon running (PID: $pid)"
        echo "Socket: $DAEMON_SOCKET"
        echo "Architecture: $TARGET_ARCH"
        return 0
    else
        echo "Daemon not running"
        return 1
    fi
}

daemon_stop() {
    if ! daemon_is_running; then
        log "WARN" "Daemon is not running"
        return 0
    fi

    local pid=$(cat "$DAEMON_PID_FILE")
    log "INFO" "Stopping daemon (PID: $pid)..."

    # Send shutdown command via socket
    if [ -S "$DAEMON_SOCKET" ]; then
        echo "===SHUTDOWN===" | socat - "UNIX-CONNECT:$DAEMON_SOCKET" 2>/dev/null || true
        sleep 2
    fi

    # If still running, kill it
    if kill -0 "$pid" 2>/dev/null; then
        log "INFO" "Sending SIGTERM..."
        kill "$pid" 2>/dev/null || true
        sleep 2
    fi

    # Force kill if necessary
    if kill -0 "$pid" 2>/dev/null; then
        log "WARN" "Sending SIGKILL..."
        kill -9 "$pid" 2>/dev/null || true
    fi

    rm -f "$DAEMON_PID_FILE" "$DAEMON_SOCKET"
    log "INFO" "Daemon stopped"
}

daemon_send() {
    local cmd="$1"

    if ! daemon_is_running; then
        log "ERROR" "Daemon is not running. Start it with --daemon-start"
        exit 1
    fi

    if [ ! -S "$DAEMON_SOCKET" ]; then
        log "ERROR" "Daemon socket not found: $DAEMON_SOCKET"
        exit 1
    fi

    # Update activity timestamp for idle timeout tracking
    touch "$DAEMON_SOCKET_DIR/activity" 2>/dev/null || true

    # Encode command in base64 and send
    local cmd_b64=$(echo -n "$cmd" | base64 -w0)

    # Send command and read response using coproc
    # This allows us to kill socat when we're done reading
    coproc SOCAT { socat - "UNIX-CONNECT:$DAEMON_SOCKET" 2>/dev/null; }

    local EXIT_CODE=0
    local in_output=false
    local TIMEOUT=60

    # Send command to socat's stdin
    echo "$cmd_b64" >&${SOCAT[1]}

    # Read response from socat's stdout with timeout
    while IFS= read -t $TIMEOUT -r line <&${SOCAT[0]}; do
        case "$line" in
            "===OUTPUT_START===")
                in_output=true
                ;;
            "===OUTPUT_END===")
                in_output=false
                ;;
            "===EXIT_CODE="*"===")
                EXIT_CODE="${line#===EXIT_CODE=}"
                EXIT_CODE="${EXIT_CODE%===}"
                ;;
            "===END===")
                break
                ;;
            *)
                if [ "$in_output" = "true" ]; then
                    echo "$line"
                fi
                ;;
        esac
    done

    # Clean up - close FDs and kill socat
    eval "exec ${SOCAT[0]}<&- ${SOCAT[1]}>&-"
    kill $SOCAT_PID 2>/dev/null || true
    wait $SOCAT_PID 2>/dev/null || true

    return ${EXIT_CODE:-0}
}

# Copy input data to shared directory and send command
daemon_send_with_input() {
    local input_path="$1"
    local input_type="$2"
    local cmd="$3"

    if ! daemon_is_running; then
        log "ERROR" "Daemon is not running. Start it with --daemon-start"
        exit 1
    fi

    # Update activity timestamp for idle timeout tracking
    touch "$DAEMON_SOCKET_DIR/activity" 2>/dev/null || true

    # Shared directory for virtio-9p
    local share_dir="$DAEMON_SOCKET_DIR/share"
    if [ ! -d "$share_dir" ]; then
        log "ERROR" "Daemon share directory not found: $share_dir"
        exit 1
    fi

    # Clear and populate shared directory
    log "INFO" "Copying input to shared directory..."
    rm -rf "$share_dir"/*

    if [ -d "$input_path" ]; then
        # Directory - copy contents (use -L to dereference symlinks)
        cp -rL "$input_path"/* "$share_dir/" 2>/dev/null || cp -r "$input_path"/* "$share_dir/"
    else
        # Single file - copy it
        cp "$input_path" "$share_dir/"
    fi

    # Sync to ensure data is visible to guest
    sync

    # Mark command as needing input (prefix with special marker)
    # Guest reads from /mnt/share (virtio-9p mount)
    local full_cmd="===USE_INPUT===$cmd"

    # Send command via daemon_send
    daemon_send "$full_cmd"
}

# Run interactive command through daemon (for run -it, exec -it)
daemon_interactive() {
    local cmd="$1"

    if ! daemon_is_running; then
        log "ERROR" "Daemon is not running"
        return 1
    fi

    if [ ! -S "$DAEMON_SOCKET" ]; then
        log "ERROR" "Daemon socket not found: $DAEMON_SOCKET"
        return 1
    fi

    # Encode command with interactive prefix
    local cmd_b64=$(echo -n "===INTERACTIVE===$cmd" | base64 -w0)

    # Use expect to handle sending command then going interactive
    # expect properly handles PTY creation and signal passthrough
    if command -v expect >/dev/null 2>&1; then
        # Disable terminal signal generation so Ctrl+C becomes byte 0x03
        local saved_stty=""
        if [ -t 0 ]; then
            saved_stty=$(stty -g)
            stty -isig
        fi

        expect -c "
            log_user 0
            set timeout -1
            spawn socat -,rawer UNIX-CONNECT:$DAEMON_SOCKET
            send \"$cmd_b64\r\"
            # Wait for READY signal before showing output
            expect \"===INTERACTIVE_READY===\" {}
            log_user 1
            # Interactive mode - exit on END marker or EOF
            interact {
                -o \"===INTERACTIVE_END\" {
                    return
                }
                eof {
                    return
                }
            }
        " 2>/dev/null
        local rc=$?

        # Restore terminal
        if [ -n "$saved_stty" ]; then
            stty "$saved_stty"
        fi
        return $rc
    fi

    # Fallback: no expect available, use basic approach (Ctrl+C won't work well)
    log "WARN" "expect not found, interactive mode may have issues with Ctrl+C"
    {
        echo "$cmd_b64"
        cat
    } | socat - "UNIX-CONNECT:$DAEMON_SOCKET"
    return $?
}

# Handle daemon modes that don't need a docker command
if [ "$DAEMON_MODE" = "status" ]; then
    daemon_status
    exit $?
fi

if [ "$DAEMON_MODE" = "stop" ]; then
    daemon_stop
    exit $?
fi

if [ "$DAEMON_MODE" = "send" ]; then
    if [ -z "$DOCKER_CMD" ]; then
        log "ERROR" "No command specified for --daemon-send"
        exit 1
    fi
    daemon_send "$DOCKER_CMD"
    exit $?
fi

if [ "$DAEMON_MODE" = "send-input" ]; then
    if [ -z "$DOCKER_CMD" ]; then
        log "ERROR" "No command specified for --daemon-send-input"
        exit 1
    fi
    if [ -z "$INPUT_PATH" ]; then
        log "ERROR" "No input specified for --daemon-send-input (use --input)"
        exit 1
    fi
    daemon_send_with_input "$INPUT_PATH" "$INPUT_TYPE" "$DOCKER_CMD"
    exit $?
fi

if [ "$DAEMON_MODE" = "interactive" ]; then
    if [ -z "$DOCKER_CMD" ]; then
        log "ERROR" "No command specified for --daemon-interactive"
        exit 1
    fi
    daemon_interactive "$DOCKER_CMD"
    exit $?
fi

# For non-daemon mode, require docker command (unless batch import)
if [ -z "$DOCKER_CMD" ] && [ "$DAEMON_MODE" != "start" ] && [ "$BATCH_IMPORT" != "true" ]; then
    log "ERROR" "No docker command specified"
    echo ""
    show_usage
    exit 1
fi

# Create temp directory early (needed for batch import and other operations)
TEMP_DIR="${TMPDIR:-/tmp}/vdkr-$$"
mkdir -p "$TEMP_DIR"

cleanup() {
    if [ "$KEEP_TEMP" = "true" ]; then
        log "DEBUG" "Keeping temp directory: $TEMP_DIR"
    else
        rm -rf "$TEMP_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# Batch import mode: parse container list and build compound command
# Format: path:image:tag path:image:tag ...
if [ "$BATCH_IMPORT" = "true" ]; then
    if [ -z "$DOCKER_CMD" ]; then
        log "ERROR" "Batch import requires container list: path:image:tag ..."
        exit 1
    fi

    log "INFO" "Batch import mode enabled"

    # Parse container entries
    BATCH_ENTRIES=()
    BATCH_PATHS=()
    BATCH_IMAGES=()

    for entry in $DOCKER_CMD; do
        # Parse path:image:tag
        # Handle colons carefully - path might have colons in edge cases
        # Format is: /path/to/oci:imagename:tag
        path="${entry%%:*}"
        rest="${entry#*:}"
        image="${rest%%:*}"
        tag="${rest#*:}"

        if [ -z "$path" ] || [ -z "$image" ] || [ -z "$tag" ]; then
            log "ERROR" "Invalid batch entry: $entry (expected path:image:tag)"
            exit 1
        fi

        if [ ! -d "$path" ]; then
            log "ERROR" "OCI directory not found: $path"
            exit 1
        fi

        BATCH_ENTRIES+=("$entry")
        BATCH_PATHS+=("$path")
        BATCH_IMAGES+=("$image:$tag")
        log "DEBUG" "Batch entry: $path -> $image:$tag"
    done

    log "INFO" "Processing ${#BATCH_ENTRIES[@]} containers"

    # Create combined input disk with numbered subdirectories
    # /0/ = first OCI dir, /1/ = second, etc.
    BATCH_INPUT_DIR="$TEMP_DIR/batch-input"
    mkdir -p "$BATCH_INPUT_DIR"

    for i in "${!BATCH_PATHS[@]}"; do
        src="${BATCH_PATHS[$i]}"
        dest="$BATCH_INPUT_DIR/$i"
        log "DEBUG" "Copying $src -> $dest"

        # Check for multi-architecture OCI Image Index
        if is_oci_image_index "$src"; then
            available_platforms=$(get_oci_platforms "$src")
            log "INFO" "Multi-arch OCI detected: $src (platforms: $available_platforms)"

            # Select manifest for target architecture
            manifest_digest=$(select_platform_manifest "$src" "$TARGET_ARCH")
            if [ -z "$manifest_digest" ]; then
                log "ERROR" "Architecture $TARGET_ARCH not found in multi-arch image: $src"
                log "ERROR" "Available platforms: $available_platforms"
                exit 1
            fi

            log "INFO" "Selected platform $(normalize_arch_to_oci "$TARGET_ARCH") from multi-arch image"

            # Extract single-platform OCI instead of copying full multi-arch
            mkdir -p "$dest"
            extract_platform_oci "$src" "$dest" "$manifest_digest"
        else
            # Single-arch OCI - copy as-is
            # Use cp -rL to dereference symlinks (OCI containers often use hardlinks)
            cp -rL "$src" "$dest"
        fi
    done

    # Override INPUT_PATH to point to combined directory
    INPUT_PATH="$BATCH_INPUT_DIR"
    INPUT_TYPE="dir"

    # Build compound skopeo command
    # Each container: skopeo copy oci:/mnt/input/N docker-daemon:image:tag
    # Note: VM init script mounts input disk at /mnt/input (see mount_input_disk)
    COMPOUND_CMD=""
    for i in "${!BATCH_IMAGES[@]}"; do
        img="${BATCH_IMAGES[$i]}"
        if [ "$RUNTIME" = "docker" ]; then
            CMD="skopeo copy oci:/mnt/input/$i docker-daemon:$img"
        else
            CMD="skopeo copy oci:/mnt/input/$i containers-storage:$img"
        fi

        if [ -z "$COMPOUND_CMD" ]; then
            COMPOUND_CMD="$CMD"
        else
            COMPOUND_CMD="$COMPOUND_CMD && $CMD"
        fi
    done

    # Add final images command to show what was imported
    if [ "$RUNTIME" = "docker" ]; then
        COMPOUND_CMD="$COMPOUND_CMD && docker images"
    else
        COMPOUND_CMD="$COMPOUND_CMD && podman images"
    fi

    log "DEBUG" "Batch command: $COMPOUND_CMD"
    DOCKER_CMD="$COMPOUND_CMD"
fi

# Auto-detect input type if input provided but type not specified
if [ -n "$INPUT_PATH" ] && [ "$INPUT_TYPE" = "none" ]; then
    if [ -d "$INPUT_PATH" ]; then
        if [ -f "$INPUT_PATH/index.json" ] || [ -f "$INPUT_PATH/oci-layout" ]; then
            INPUT_TYPE="oci"
        else
            INPUT_TYPE="dir"
        fi
    elif [ -f "$INPUT_PATH" ]; then
        INPUT_TYPE="tar"
    fi
    log "DEBUG" "Auto-detected input type: $INPUT_TYPE"
fi

# Validate output file for types that need it
if [ "$OUTPUT_TYPE" = "tar" ] || [ "$OUTPUT_TYPE" = "storage" ]; then
    if [ -z "$OUTPUT_FILE" ]; then
        OUTPUT_FILE="/tmp/vdkr-output-$$.tar"
        log "WARN" "No --output specified, using: $OUTPUT_FILE"
    fi
fi

log "INFO" "vdkr-run v$VERSION"
log "INFO" "Architecture: $TARGET_ARCH"
log "INFO" "Docker command: $DOCKER_CMD"
[ -n "$INPUT_PATH" ] && log "INFO" "Input: $INPUT_PATH ($INPUT_TYPE)"
[ -n "$INPUT_STORAGE" ] && log "INFO" "Input storage: $INPUT_STORAGE"
[ -n "$STATE_DIR" ] && log "INFO" "State directory: $STATE_DIR"
log "INFO" "Output type: $OUTPUT_TYPE"
[ -n "$OUTPUT_FILE" ] && log "INFO" "Output file: $OUTPUT_FILE"
[ "$NETWORK" = "true" ] && log "INFO" "Networking: enabled (slirp)"
[ "$INTERACTIVE" = "true" ] && log "INFO" "Interactive mode: enabled"

# Find kernel, initramfs, and rootfs
case "$TARGET_ARCH" in
    aarch64)
        KERNEL_IMAGE="$BLOB_DIR/aarch64/Image"
        INITRAMFS="$BLOB_DIR/aarch64/initramfs.cpio.gz"
        ROOTFS_IMG="$BLOB_DIR/aarch64/rootfs.img"
        QEMU_CMD="qemu-system-aarch64"
        QEMU_MACHINE="-M virt -cpu cortex-a57"
        CONSOLE="ttyAMA0"
        ;;
    x86_64)
        KERNEL_IMAGE="$BLOB_DIR/x86_64/bzImage"
        INITRAMFS="$BLOB_DIR/x86_64/initramfs.cpio.gz"
        ROOTFS_IMG="$BLOB_DIR/x86_64/rootfs.img"
        QEMU_CMD="qemu-system-x86_64"
        # Use q35 + Skylake-Client to match oe-core qemux86-64 machine
        QEMU_MACHINE="-M q35 -cpu Skylake-Client"
        CONSOLE="ttyS0"
        ;;
    *)
        log "ERROR" "Unsupported architecture: $TARGET_ARCH"
        exit 1
        ;;
esac

# Check for kernel
if [ ! -f "$KERNEL_IMAGE" ]; then
    log "ERROR" "Kernel not found: $KERNEL_IMAGE"
    log "ERROR" "Set VDKR_BLOB_DIR or --blob-dir to location of vdkr blobs"
    log "ERROR" "Build with: MACHINE=qemuarm64 bitbake vdkr-initramfs-build"
    exit 1
fi

# Check for initramfs
if [ ! -f "$INITRAMFS" ]; then
    log "ERROR" "Initramfs not found: $INITRAMFS"
    log "ERROR" "Build with: MACHINE=qemuarm64 bitbake vdkr-initramfs-build"
    exit 1
fi

# Check for rootfs image (ext4 with Docker tools)
if [ ! -f "$ROOTFS_IMG" ]; then
    log "ERROR" "Rootfs image not found: $ROOTFS_IMG"
    log "ERROR" "Build with: MACHINE=qemuarm64 bitbake vdkr-initramfs-create"
    exit 1
fi

# Find QEMU - check PATH and common locations
if ! command -v "$QEMU_CMD" >/dev/null 2>&1; then
    # Try common locations
    for path in \
        "${STAGING_BINDIR_NATIVE:-}" \
        "/usr/bin"; do
        if [ -n "$path" ] && [ -x "$path/$QEMU_CMD" ]; then
            QEMU_CMD="$path/$QEMU_CMD"
            break
        fi
    done
fi

if ! command -v "$QEMU_CMD" >/dev/null 2>&1 && [ ! -x "$QEMU_CMD" ]; then
    log "ERROR" "QEMU not found: $QEMU_CMD"
    exit 1
fi

log "DEBUG" "Using QEMU: $QEMU_CMD"

# Check for KVM acceleration (when host matches target)
USE_KVM="false"
if [ "$DISABLE_KVM" = "true" ]; then
    log "DEBUG" "KVM disabled by --no-kvm flag"
else
    HOST_ARCH=$(uname -m)
    if [ "$HOST_ARCH" = "$TARGET_ARCH" ] || \
       { [ "$HOST_ARCH" = "x86_64" ] && [ "$TARGET_ARCH" = "x86_64" ]; }; then
        if [ -w /dev/kvm ]; then
            USE_KVM="true"
            # Use host CPU for best performance with KVM
            case "$TARGET_ARCH" in
                x86_64)
                    QEMU_MACHINE="-M q35 -cpu host"
                    ;;
                aarch64)
                    QEMU_MACHINE="-M virt -cpu host"
                    ;;
            esac
            log "INFO" "KVM acceleration enabled"
        else
            log "DEBUG" "KVM not available (no write access to /dev/kvm)"
        fi
    fi
fi

log "DEBUG" "Using initramfs: $INITRAMFS"

# Create input disk image if needed
DISK_OPTS=""
if [ -n "$INPUT_PATH" ] && [ "$INPUT_TYPE" != "none" ]; then
    log "INFO" "Creating input disk image..."
    INPUT_IMG="$TEMP_DIR/input.img"

    # Calculate size (use -L to dereference hardlinks in OCI containers)
    if [ -d "$INPUT_PATH" ]; then
        SIZE_KB=$(du -skL "$INPUT_PATH" | cut -f1)
    else
        SIZE_KB=$(($(stat -c%s "$INPUT_PATH") / 1024))
    fi
    SIZE_MB=$(( (SIZE_KB / 1024) + 20 ))
    [ $SIZE_MB -lt 20 ] && SIZE_MB=20

    log "DEBUG" "Input size: ${SIZE_KB}KB, Image size: ${SIZE_MB}MB"

    dd if=/dev/zero of="$INPUT_IMG" bs=1M count=$SIZE_MB 2>/dev/null

    if [ -d "$INPUT_PATH" ]; then
        mke2fs -t ext4 -d "$INPUT_PATH" "$INPUT_IMG" 2>/dev/null
    else
        # Single file - create temp dir with the file
        EXTRACT_DIR="$TEMP_DIR/input-extract"
        mkdir -p "$EXTRACT_DIR"
        cp "$INPUT_PATH" "$EXTRACT_DIR/"
        mke2fs -t ext4 -d "$EXTRACT_DIR" "$INPUT_IMG" 2>/dev/null
    fi

    DISK_OPTS="-drive file=$INPUT_IMG,if=virtio,format=raw"
    log "DEBUG" "Input disk: $(ls -lh "$INPUT_IMG" | awk '{print $5}')"
fi

# Create state disk for persistent storage (--state-dir)
STATE_DISK_OPTS=""
if [ -n "$STATE_DIR" ]; then
    mkdir -p "$STATE_DIR"
    STATE_IMG="$STATE_DIR/$STATE_FILE"

    # Migration: vpdmn used to use docker-state.img, now uses podman-state.img
    # If old file exists but new file doesn't, rename it automatically
    if [ "$STATE_FILE" = "podman-state.img" ]; then
        OLD_STATE_IMG="$STATE_DIR/docker-state.img"
        if [ -f "$OLD_STATE_IMG" ] && [ ! -f "$STATE_IMG" ]; then
            log "INFO" "Migrating old vpdmn state file: docker-state.img -> podman-state.img"
            mv "$OLD_STATE_IMG" "$STATE_IMG"
        fi
    fi

    if [ ! -f "$STATE_IMG" ]; then
        log "INFO" "Creating new state disk at $STATE_IMG..."
        # Create 2GB state disk for Docker storage
        dd if=/dev/zero of="$STATE_IMG" bs=1M count=2048 2>/dev/null
        mke2fs -t ext4 "$STATE_IMG" 2>/dev/null
    else
        log "INFO" "Using existing state disk: $STATE_IMG"
    fi

    # Use cache=directsync to ensure writes are flushed to disk
    # Combined with graceful shutdown wait, this ensures data integrity
    STATE_DISK_OPTS="-drive file=$STATE_IMG,if=virtio,format=raw,cache=directsync"
    log "DEBUG" "State disk: $(ls -lh "$STATE_IMG" | awk '{print $5}')"
fi

# Create state disk from input-storage tar (--input-storage)
if [ -n "$INPUT_STORAGE" ] && [ -z "$STATE_DIR" ]; then
    if [ ! -f "$INPUT_STORAGE" ]; then
        log "ERROR" "Input storage file not found: $INPUT_STORAGE"
        exit 1
    fi

    log "INFO" "Creating state disk from $INPUT_STORAGE..."
    STATE_IMG="$TEMP_DIR/state.img"

    # Calculate size from tar + headroom
    TAR_SIZE_KB=$(($(stat -c%s "$INPUT_STORAGE") / 1024))
    STATE_SIZE_MB=$(( (TAR_SIZE_KB / 1024) * 2 + 500 ))  # 2x tar size + 500MB headroom
    [ $STATE_SIZE_MB -lt 500 ] && STATE_SIZE_MB=500

    log "DEBUG" "Tar size: ${TAR_SIZE_KB}KB, State disk: ${STATE_SIZE_MB}MB"

    dd if=/dev/zero of="$STATE_IMG" bs=1M count=$STATE_SIZE_MB 2>/dev/null
    mke2fs -t ext4 "$STATE_IMG" 2>/dev/null

    # Mount and extract tar
    MOUNT_DIR="$TEMP_DIR/state-mount"
    mkdir -p "$MOUNT_DIR"

    # Use fuse2fs if available, otherwise need root
    # Note: We exclude special device files that can't be created without root
    # Docker's backingFsBlockDev is a block device that gets recreated at runtime anyway
    # IMPORTANT: The tar has paths like docker/image/... but the state disk is mounted
    # at /var/lib/docker, so we need to strip the docker/ prefix with --strip-components=1
    if command -v fuse2fs >/dev/null 2>&1; then
        fuse2fs "$STATE_IMG" "$MOUNT_DIR" -o rw
        tar --no-same-owner --strip-components=1 --exclude=volumes/backingFsBlockDev -xf "$INPUT_STORAGE" -C "$MOUNT_DIR"
        fusermount -u "$MOUNT_DIR"
    else
        log "WARN" "fuse2fs not found, using debugfs to inject tar (slower)"
        # Extract tar to temp, then use mke2fs -d
        # Use --no-same-owner since we're not root (ownership set to current user)
        EXTRACT_DIR="$TEMP_DIR/state-extract"
        mkdir -p "$EXTRACT_DIR"
        tar --no-same-owner --strip-components=1 --exclude=volumes/backingFsBlockDev -xf "$INPUT_STORAGE" -C "$EXTRACT_DIR"
        mke2fs -t ext4 -d "$EXTRACT_DIR" "$STATE_IMG" 2>/dev/null
    fi

    # Use cache=directsync to ensure writes are flushed to disk
    STATE_DISK_OPTS="-drive file=$STATE_IMG,if=virtio,format=raw,cache=directsync"
    log "DEBUG" "State disk: $(ls -lh "$STATE_IMG" | awk '{print $5}')"
fi

# Encode command as base64
DOCKER_CMD_B64=$(echo -n "$DOCKER_CMD" | base64 -w0)

# Build kernel command line
# In interactive mode, use 'quiet' to suppress kernel boot messages
# Use CMDLINE_PREFIX for runtime-specific parameters (docker_ or podman_)
if [ "$INTERACTIVE" = "true" ]; then
    KERNEL_APPEND="console=$CONSOLE,115200 quiet loglevel=0 init=/init"
else
    KERNEL_APPEND="console=$CONSOLE,115200 init=/init"
fi
# Tell init script which runtime we're using
KERNEL_APPEND="$KERNEL_APPEND runtime=$RUNTIME"
KERNEL_APPEND="$KERNEL_APPEND ${CMDLINE_PREFIX}_cmd=$DOCKER_CMD_B64"
KERNEL_APPEND="$KERNEL_APPEND ${CMDLINE_PREFIX}_input=$INPUT_TYPE"
KERNEL_APPEND="$KERNEL_APPEND ${CMDLINE_PREFIX}_output=$OUTPUT_TYPE"

# Tell init script if we have a state disk
if [ -n "$STATE_DISK_OPTS" ]; then
    KERNEL_APPEND="$KERNEL_APPEND ${CMDLINE_PREFIX}_state=disk"
fi

# Tell init script if networking is enabled
if [ "$NETWORK" = "true" ]; then
    KERNEL_APPEND="$KERNEL_APPEND ${CMDLINE_PREFIX}_network=1"
fi

# Registry configuration for unqualified image names
if [ -n "$DOCKER_REGISTRY" ]; then
    KERNEL_APPEND="$KERNEL_APPEND ${CMDLINE_PREFIX}_registry=$DOCKER_REGISTRY"
fi

# Insecure registries (HTTP)
for reg in "${INSECURE_REGISTRIES[@]}"; do
    KERNEL_APPEND="$KERNEL_APPEND ${CMDLINE_PREFIX}_insecure_registry=$reg"
done

# Secure registry mode (TLS verification)
# CA certificate is passed via virtio-9p share, not kernel cmdline (too large)
if [ "$SECURE_REGISTRY" = "true" ]; then
    KERNEL_APPEND="$KERNEL_APPEND ${CMDLINE_PREFIX}_registry_secure=1"
fi

# Registry credentials
if [ -n "$REGISTRY_USER" ]; then
    KERNEL_APPEND="$KERNEL_APPEND ${CMDLINE_PREFIX}_registry_user=$REGISTRY_USER"
fi
if [ -n "$REGISTRY_PASS" ]; then
    # Base64 encode the password to handle special characters
    REGISTRY_PASS_B64=$(echo -n "$REGISTRY_PASS" | base64 -w0)
    KERNEL_APPEND="$KERNEL_APPEND ${CMDLINE_PREFIX}_registry_pass=$REGISTRY_PASS_B64"
fi

# Tell init script if interactive mode
if [ "$INTERACTIVE" = "true" ]; then
    KERNEL_APPEND="$KERNEL_APPEND ${CMDLINE_PREFIX}_interactive=1"
fi

# Build QEMU command
# Drive ordering is important:
#   /dev/vda = rootfs.img (read-only, ext4 with Docker tools)
#   /dev/vdb = input disk (if any)
#   /dev/vdc = state disk (if any)
# The preinit script in initramfs mounts /dev/vda and does switch_root
# Build QEMU options
QEMU_OPTS="$QEMU_MACHINE -nographic -smp 2 -m 2048 -no-reboot"
if [ "$USE_KVM" = "true" ]; then
    QEMU_OPTS="$QEMU_OPTS -enable-kvm"
fi
QEMU_OPTS="$QEMU_OPTS -kernel $KERNEL_IMAGE"
QEMU_OPTS="$QEMU_OPTS -initrd $INITRAMFS"
QEMU_OPTS="$QEMU_OPTS -drive file=$ROOTFS_IMG,if=virtio,format=raw,readonly=on"
QEMU_OPTS="$QEMU_OPTS $DISK_OPTS"
QEMU_OPTS="$QEMU_OPTS $STATE_DISK_OPTS"

# Add networking if enabled (slirp user-mode networking)
if [ "$NETWORK" = "true" ]; then
    # Slirp provides NAT'd outbound connectivity without root privileges
    # Guest gets 10.0.2.15, gateway is 10.0.2.2, DNS is 10.0.2.3
    NETDEV_OPTS="user,id=net0"

    # Add port forwards - QEMU forwards host:port -> VM:port
    # Docker's iptables handles VM:port -> container:port
    for pf in "${PORT_FORWARDS[@]}"; do
        # Parse host_port:container_port or host_port:container_port/protocol
        HOST_PORT="${pf%%:*}"
        CONTAINER_PART="${pf#*:}"
        CONTAINER_PORT="${CONTAINER_PART%%/*}"

        # Check for protocol suffix (default to tcp)
        if [[ "$CONTAINER_PART" == */* ]]; then
            PROTOCOL="${CONTAINER_PART##*/}"
        else
            PROTOCOL="tcp"
        fi

        # Forward to HOST_PORT on VM; Docker -p handles container port mapping
        NETDEV_OPTS="$NETDEV_OPTS,hostfwd=$PROTOCOL::$HOST_PORT-:$HOST_PORT"
        log "INFO" "Port forward: host:$HOST_PORT -> VM:$HOST_PORT (Docker maps to container:$CONTAINER_PORT)"
    done

    QEMU_OPTS="$QEMU_OPTS -netdev $NETDEV_OPTS -device virtio-net-pci,netdev=net0"
else
    # Explicitly disable networking
    QEMU_OPTS="$QEMU_OPTS -nic none"
fi

# Batch-import mode: add virtio-9p for fast output (instead of slow console base64)
if [ "$BATCH_IMPORT" = "true" ]; then
    BATCH_SHARE_DIR="$TEMP_DIR/share"
    mkdir -p "$BATCH_SHARE_DIR"
    SHARE_TAG="${TOOL_NAME}_share"
    QEMU_OPTS="$QEMU_OPTS -virtfs local,path=$BATCH_SHARE_DIR,mount_tag=$SHARE_TAG,security_model=none,id=$SHARE_TAG"
    KERNEL_APPEND="$KERNEL_APPEND ${CMDLINE_PREFIX}_9p=1"
    log "INFO" "Using virtio-9p for fast storage output"
fi

# Daemon mode: add virtio-serial for command channel
if [ "$DAEMON_MODE" = "start" ]; then
    # Check for required tools
    if ! command -v socat >/dev/null 2>&1; then
        log "ERROR" "Daemon mode requires 'socat' but it is not installed."
        log "ERROR" "Install with: sudo apt install socat"
        exit 1
    fi

    # Check if daemon is already running
    if daemon_is_running; then
        log "ERROR" "Daemon is already running. Use --daemon-stop first."
        exit 1
    fi

    # Create socket directory
    mkdir -p "$DAEMON_SOCKET_DIR"

    # Create shared directory for file I/O (virtio-9p)
    DAEMON_SHARE_DIR="$DAEMON_SOCKET_DIR/share"
    mkdir -p "$DAEMON_SHARE_DIR"

    # Add virtio-9p for shared directory access
    # Host writes to $DAEMON_SHARE_DIR, guest mounts as /mnt/share
    # Use runtime-specific mount tag (vdkr_share or vpdmn_share)
    SHARE_TAG="${TOOL_NAME}_share"
    # Use security_model=none for simplest file sharing (no permission mapping)
    # This allows writes from container (running as root) to propagate to host
    QEMU_OPTS="$QEMU_OPTS -virtfs local,path=$DAEMON_SHARE_DIR,mount_tag=$SHARE_TAG,security_model=none,id=$SHARE_TAG"
    # Tell init script to mount the share
    KERNEL_APPEND="$KERNEL_APPEND ${CMDLINE_PREFIX}_9p=1"

    # Add virtio-serial device for command channel
    # Using virtserialport creates /dev/vport0p1 in guest, host sees unix socket
    # virtconsole would use hvc* but requires virtio_console kernel module
    QEMU_OPTS="$QEMU_OPTS -chardev socket,id=vdkr,path=$DAEMON_SOCKET,server=on,wait=off"
    QEMU_OPTS="$QEMU_OPTS -device virtio-serial-pci"
    QEMU_OPTS="$QEMU_OPTS -device virtserialport,chardev=vdkr,name=vdkr"

    # Add QMP socket for dynamic control (port forwarding, etc.)
    QMP_SOCKET="$DAEMON_SOCKET_DIR/qmp.sock"
    QEMU_OPTS="$QEMU_OPTS -qmp unix:$QMP_SOCKET,server,nowait"

    # Tell init script to run in daemon mode with idle timeout
    KERNEL_APPEND="$KERNEL_APPEND ${CMDLINE_PREFIX}_daemon=1"
    KERNEL_APPEND="$KERNEL_APPEND ${CMDLINE_PREFIX}_idle_timeout=$IDLE_TIMEOUT"

    # Always enable networking for daemon mode
    if [ "$NETWORK" != "true" ]; then
        log "INFO" "Enabling networking for daemon mode"
        NETWORK="true"
        # Build netdev options with any port forwards
        DAEMON_NETDEV="user,id=net0"
        for pf in "${PORT_FORWARDS[@]}"; do
            # Parse host_port:container_port or host_port:container_port/protocol
            HOST_PORT="${pf%%:*}"
            CONTAINER_PART="${pf#*:}"
            CONTAINER_PORT="${CONTAINER_PART%%/*}"
            if [[ "$CONTAINER_PART" == */* ]]; then
                PROTOCOL="${CONTAINER_PART##*/}"
            else
                PROTOCOL="tcp"
            fi
            # Forward to HOST_PORT on VM; Docker -p handles container port mapping
            DAEMON_NETDEV="$DAEMON_NETDEV,hostfwd=$PROTOCOL::$HOST_PORT-:$HOST_PORT"
            log "INFO" "Port forward: host:$HOST_PORT -> VM:$HOST_PORT (Docker maps to container:$CONTAINER_PORT)"
        done
        QEMU_OPTS="$QEMU_OPTS -netdev $DAEMON_NETDEV -device virtio-net-pci,netdev=net0"
    else
        # NETWORK was already true, but check if we need to add port forwards
        # that weren't included in the earlier networking setup
        # (This happens when NETWORK was set to true before daemon mode was detected)
        if [ ${#PORT_FORWARDS[@]} -gt 0 ]; then
            # Port forwards should already be included from earlier networking setup
            for pf in "${PORT_FORWARDS[@]}"; do
                HOST_PORT="${pf%%:*}"
                CONTAINER_PART="${pf#*:}"
                CONTAINER_PORT="${CONTAINER_PART%%/*}"
                log "INFO" "Port forward configured: $HOST_PORT -> $CONTAINER_PORT"
            done
        fi
    fi

    # Copy CA certificate to shared folder (too large for kernel cmdline)
    if [ -n "$CA_CERT" ] && [ -f "$CA_CERT" ]; then
        cp "$CA_CERT" "$DAEMON_SHARE_DIR/ca.crt"
        log "DEBUG" "CA certificate copied to shared folder"
    fi

    log "INFO" "Starting daemon..."
    log "DEBUG" "PID file: $DAEMON_PID_FILE"
    log "DEBUG" "Socket: $DAEMON_SOCKET"
    log "DEBUG" "Command: $QEMU_CMD $QEMU_OPTS -append \"$KERNEL_APPEND\""

    # Start QEMU in background
    $QEMU_CMD $QEMU_OPTS -append "$KERNEL_APPEND" > "$DAEMON_QEMU_LOG" 2>&1 &
    QEMU_PID=$!
    echo "$QEMU_PID" > "$DAEMON_PID_FILE"

    log "INFO" "QEMU started (PID: $QEMU_PID)"

    # Wait for socket to appear (Docker starting)
    # Docker can take 60+ seconds to start, so wait up to 120 seconds
    log "INFO" "Waiting for daemon to be ready..."
    READY=false
    for i in $(seq 1 120); do
        if [ -S "$DAEMON_SOCKET" ]; then
            # Socket exists, try to connect
            # Keep stdin open for 3 seconds to allow response to arrive
            RESPONSE=$( { echo "===PING==="; sleep 3; } | timeout 10 socat - "UNIX-CONNECT:$DAEMON_SOCKET" 2>/dev/null || true)
            if echo "$RESPONSE" | grep -q "===PONG==="; then
                log "DEBUG" "Got PONG response"
                READY=true
                break
            else
                log "DEBUG" "No PONG, got: $RESPONSE"
            fi
        fi

        # Check if QEMU died
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            log "ERROR" "QEMU process died during startup"
            cat "$DAEMON_QEMU_LOG" >&2
            rm -f "$DAEMON_PID_FILE"
            exit 1
        fi

        log "DEBUG" "Waiting... ($i/60)"
        sleep 1
    done

    if [ "$READY" = "true" ]; then
        log "INFO" "Daemon is ready!"

        # Start host-side idle watchdog if timeout is set
        if [ "$IDLE_TIMEOUT" -gt 0 ] 2>/dev/null; then
            ACTIVITY_FILE="$DAEMON_SOCKET_DIR/activity"
            touch "$ACTIVITY_FILE"

            # Spawn background watchdog
            (
                # Container status file - guest writes this via virtio-9p share
                # This avoids sending commands through daemon socket which corrupts output
                CONTAINER_STATUS_FILE="$DAEMON_SHARE_DIR/.containers_running"

                # Scale check interval to idle timeout (check ~5 times before timeout)
                CHECK_INTERVAL=$((IDLE_TIMEOUT / 5))
                [ "$CHECK_INTERVAL" -lt 10 ] && CHECK_INTERVAL=10
                [ "$CHECK_INTERVAL" -gt 60 ] && CHECK_INTERVAL=60

                while true; do
                    sleep "$CHECK_INTERVAL"
                    [ -f "$ACTIVITY_FILE" ] || exit 0  # Clean exit if file removed
                    [ -f "$DAEMON_PID_FILE" ] || exit 0  # PID file gone

                    # Check if QEMU process is still running
                    QEMU_PID=$(cat "$DAEMON_PID_FILE" 2>/dev/null)
                    [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null || exit 0

                    LAST_ACTIVITY=$(stat -c %Y "$ACTIVITY_FILE" 2>/dev/null || echo 0)
                    NOW=$(date +%s)
                    IDLE_SECONDS=$((NOW - LAST_ACTIVITY))

                    if [ "$IDLE_SECONDS" -ge "$IDLE_TIMEOUT" ]; then
                        # Check if any containers are running via shared file
                        # Guest-side watchdog writes container IDs to this file
                        if [ -f "$CONTAINER_STATUS_FILE" ] && [ -s "$CONTAINER_STATUS_FILE" ]; then
                            # Containers are running - reset activity and skip shutdown
                            touch "$ACTIVITY_FILE"
                            continue
                        fi

                        # No containers running - send QMP quit to gracefully stop QEMU
                        if [ -S "$QMP_SOCKET" ]; then
                            echo '{"execute":"qmp_capabilities"}{"execute":"quit"}' | \
                                socat - "UNIX-CONNECT:$QMP_SOCKET" >/dev/null 2>&1 || true
                        fi
                        rm -f "$ACTIVITY_FILE"
                        exit 0
                    fi
                done
            ) &
            log "DEBUG" "Started host-side idle watchdog (timeout: ${IDLE_TIMEOUT}s)"
        fi

        echo "Daemon running (PID: $QEMU_PID)"
        echo "Socket: $DAEMON_SOCKET"
        exit 0
    else
        log "ERROR" "Daemon failed to become ready within 120 seconds"
        cat "$DAEMON_QEMU_LOG" >&2
        kill "$QEMU_PID" 2>/dev/null || true
        rm -f "$DAEMON_PID_FILE" "$DAEMON_SOCKET"
        exit 1
    fi
fi

# For non-daemon mode with CA cert, we need virtio-9p to pass the cert
# (kernel cmdline is too small for base64-encoded certs)
if [ -n "$CA_CERT" ] && [ -f "$CA_CERT" ]; then
    # Create temp share dir for CA cert
    CA_SHARE_DIR="$TEMP_DIR/ca_share"
    mkdir -p "$CA_SHARE_DIR"
    cp "$CA_CERT" "$CA_SHARE_DIR/ca.crt"

    # Add virtio-9p mount for CA cert
    SHARE_TAG="${TOOL_NAME}_share"
    QEMU_OPTS="$QEMU_OPTS -virtfs local,path=$CA_SHARE_DIR,mount_tag=$SHARE_TAG,security_model=none,readonly=on,id=cashare"
    KERNEL_APPEND="$KERNEL_APPEND ${CMDLINE_PREFIX}_9p=1"
    log "DEBUG" "CA certificate available via virtio-9p"
fi

log "INFO" "Starting QEMU..."
log "DEBUG" "Command: $QEMU_CMD $QEMU_OPTS -append \"$KERNEL_APPEND\""

# Interactive mode runs QEMU in foreground with stdio connected
if [ "$INTERACTIVE" = "true" ]; then
    # Check if stdin is a terminal
    if [ ! -t 0 ]; then
        log "WARN" "Interactive mode requested but stdin is not a terminal"
    fi

    # Show a starting message
    # The init script will clear this line when the container is ready
    if [ -t 1 ]; then
        printf "\r\033[0;36m[vdkr]\033[0m Starting container... \r"
    fi

    # Save terminal settings to restore later
    if [ -t 0 ]; then
        SAVED_STTY=$(stty -g)
        # Put terminal in raw mode so Ctrl+C etc go to guest
        stty raw -echo
    fi

    # Run QEMU with stdio (not in background)
    # The -serial mon:stdio connects the serial console to our terminal
    $QEMU_CMD $QEMU_OPTS -append "$KERNEL_APPEND"
    QEMU_EXIT=$?

    # Restore terminal settings
    if [ -t 0 ]; then
        stty "$SAVED_STTY"
    fi

    echo ""
    log "INFO" "Interactive session ended (exit code: $QEMU_EXIT)"
    exit $QEMU_EXIT
fi

# Non-interactive mode: run QEMU in background and capture output
QEMU_OUTPUT="$TEMP_DIR/qemu_output.txt"
timeout $TIMEOUT $QEMU_CMD $QEMU_OPTS -append "$KERNEL_APPEND" > "$QEMU_OUTPUT" 2>&1 &
QEMU_PID=$!

# Monitor for completion
COMPLETE=false
for i in $(seq 1 $TIMEOUT); do
    if [ ! -d "/proc/$QEMU_PID" ]; then
        log "DEBUG" "QEMU ended after $i seconds"
        break
    fi

    # Check for completion markers based on output type
    case "$OUTPUT_TYPE" in
        text)
            if grep -q "===OUTPUT_END===" "$QEMU_OUTPUT" 2>/dev/null; then
                COMPLETE=true
                break
            fi
            ;;
        tar)
            if grep -q "===TAR_END===" "$QEMU_OUTPUT" 2>/dev/null; then
                COMPLETE=true
                break
            fi
            ;;
        storage)
            # Check for both console (STORAGE_END) and virtio-9p (9P_STORAGE_DONE) markers
            if grep -qE "===STORAGE_END===|===9P_STORAGE_DONE===" "$QEMU_OUTPUT" 2>/dev/null; then
                COMPLETE=true
                break
            fi
            ;;
    esac

    # Check for error
    if grep -q "===ERROR===" "$QEMU_OUTPUT" 2>/dev/null; then
        log "ERROR" "Error in QEMU:"
        grep -A10 "===ERROR===" "$QEMU_OUTPUT"
        break
    fi

    # Progress indicator
    if [ $((i % 30)) -eq 0 ]; then
        if grep -q "Docker daemon is ready" "$QEMU_OUTPUT" 2>/dev/null; then
            log "INFO" "Docker is running, executing command..."
        elif grep -q "Starting Docker" "$QEMU_OUTPUT" 2>/dev/null; then
            log "INFO" "Docker is starting..."
        fi
    fi

    sleep 1
done

# Wait for QEMU to exit gracefully (poweroff from inside flushes disks properly)
# Only kill if it hangs after seeing completion marker
if [ "$COMPLETE" = "true" ] && [ -d "/proc/$QEMU_PID" ]; then
    log "DEBUG" "Waiting for QEMU to complete graceful shutdown..."
    # Give QEMU up to 30 seconds to poweroff after command completes
    for wait_i in $(seq 1 30); do
        if [ ! -d "/proc/$QEMU_PID" ]; then
            log "DEBUG" "QEMU shutdown complete"
            break
        fi
        sleep 1
    done
fi

# Force kill QEMU only if still running after grace period
if [ -d "/proc/$QEMU_PID" ]; then
    log "WARN" "QEMU still running, forcing termination..."
    kill $QEMU_PID 2>/dev/null || true
    wait $QEMU_PID 2>/dev/null || true
fi

# Extract results
if [ "$COMPLETE" = "true" ]; then
    # Get exit code
    EXIT_CODE=$(grep -oP '===EXIT_CODE=\K[0-9]+' "$QEMU_OUTPUT" | head -1)
    EXIT_CODE="${EXIT_CODE:-0}"

    case "$OUTPUT_TYPE" in
        text)
            log "INFO" "=== Command Output ==="
            # Use awk for precise extraction between markers
            awk '/===OUTPUT_START===/{capture=1; next} /===OUTPUT_END===/{capture=0} capture' "$QEMU_OUTPUT"
            log "INFO" "=== Exit Code: $EXIT_CODE ==="
            ;;

        tar)
            log "INFO" "Extracting tar output..."
            # Use awk for precise extraction between markers
            # Strip ANSI escape codes and non-base64 characters from serial console output
            awk '/===TAR_START===/{capture=1; next} /===TAR_END===/{capture=0} capture' "$QEMU_OUTPUT" | \
                tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g' | tr -cd 'A-Za-z0-9+/=\n' | base64 -d > "$OUTPUT_FILE" 2>"${TEMP_DIR}/b64_errors.txt"

            if [ -s "${TEMP_DIR}/b64_errors.txt" ]; then
                log "WARN" "Base64 decode warnings: $(cat "${TEMP_DIR}/b64_errors.txt")"
            fi

            if tar -tf "$OUTPUT_FILE" >/dev/null 2>&1; then
                log "INFO" "SUCCESS: Output saved to $OUTPUT_FILE"
                log "INFO" "Size: $(ls -lh "$OUTPUT_FILE" | awk '{print $5}')"
            else
                log "ERROR" "Output file is not a valid tar"
                exit 1
            fi
            ;;

        storage)
            log "INFO" "Extracting storage..."

            # Check for virtio-9p shared directory first (fast path)
            if [ -n "$BATCH_SHARE_DIR" ] && [ -f "$BATCH_SHARE_DIR/storage.tar" ]; then
                log "INFO" "Using virtio-9p storage output (fast path)"
                cp "$BATCH_SHARE_DIR/storage.tar" "$OUTPUT_FILE"
            else
                # Fallback: extract from console base64 (slow path)
                log "INFO" "Using console base64 output (slow path)"
                # Use awk for precise extraction: capture lines between markers (not including markers)
                # Pipeline:
                # 1. awk: extract lines between STORAGE_START and STORAGE_END markers
                # 2. tr -d '\r': remove carriage returns
                # 3. sed: remove ANSI escape codes
                # 4. grep -v: remove kernel log messages (lines starting with [ followed by timestamp)
                # 5. tr -cd: keep only valid base64 characters
                awk '/===STORAGE_START===/{capture=1; next} /===STORAGE_END===/{capture=0} capture' "$QEMU_OUTPUT" | \
                    tr -d '\r' | \
                    sed 's/\x1b\[[0-9;]*m//g' | \
                    grep -v '^\[[[:space:]]*[0-9]' | \
                    tr -cd 'A-Za-z0-9+/=\n' > "${TEMP_DIR}/storage_b64.txt"

                B64_SIZE=$(wc -c < "${TEMP_DIR}/storage_b64.txt")
                log "DEBUG" "Base64 data extracted: $B64_SIZE bytes"

                # Decode with error reporting (not suppressed)
                if ! base64 -d < "${TEMP_DIR}/storage_b64.txt" > "$OUTPUT_FILE" 2>"${TEMP_DIR}/b64_errors.txt"; then
                    log "ERROR" "Base64 decode failed"
                    if [ -s "${TEMP_DIR}/b64_errors.txt" ]; then
                        log "ERROR" "Decode errors: $(cat "${TEMP_DIR}/b64_errors.txt")"
                    fi
                    # Show a sample of the base64 data for debugging
                    log "DEBUG" "First 200 chars of base64: $(head -c 200 "${TEMP_DIR}/storage_b64.txt")"
                    log "DEBUG" "Last 200 chars of base64: $(tail -c 200 "${TEMP_DIR}/storage_b64.txt")"
                    exit 1
                fi
            fi

            DECODED_SIZE=$(wc -c < "$OUTPUT_FILE")
            log "DEBUG" "Decoded storage size: $DECODED_SIZE bytes"

            if tar -tf "$OUTPUT_FILE" >/dev/null 2>&1; then
                log "INFO" "SUCCESS: Docker storage saved to $OUTPUT_FILE"
                log "INFO" "Size: $(ls -lh "$OUTPUT_FILE" | awk '{print $5}')"
                log "INFO" ""
                log "INFO" "To deploy: tar -xf $OUTPUT_FILE -C /var/lib/"
            else
                log "ERROR" "Storage file is not a valid tar (size: $DECODED_SIZE bytes)"
                log "DEBUG" "Tar validation output: $(tar -tf "$OUTPUT_FILE" 2>&1 | head -10)"
                exit 1
            fi
            ;;
    esac

    exit "${EXIT_CODE:-0}"
else
    log "ERROR" "Command execution failed or timed out"
    log "ERROR" "QEMU output saved to: $QEMU_OUTPUT"

    if [ "$VERBOSE" = "true" ]; then
        log "DEBUG" "=== Last 50 lines of QEMU output ==="
        tail -50 "$QEMU_OUTPUT"
    fi

    exit 1
fi

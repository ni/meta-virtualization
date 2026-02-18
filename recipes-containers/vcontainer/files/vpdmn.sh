#!/bin/bash
# SPDX-FileCopyrightText: Copyright (C) 2025 Bruce Ashfield
#
# SPDX-License-Identifier: GPL-2.0-only
#
# vpdmn: Podman-like interface for cross-architecture container operations
#
# This provides a familiar podman-like CLI that executes commands inside
# a QEMU-emulated environment with the target architecture's Podman.
#
# Command naming convention:
#   - Commands matching Podman's syntax/semantics use Podman's name (import, load, save, etc.)
#   - Extended commands with non-Podman behavior use 'v' prefix (vimport)

# Set runtime-specific parameters before sourcing common code
VCONTAINER_RUNTIME_NAME="vpdmn"
VCONTAINER_RUNTIME_CMD="podman"
VCONTAINER_RUNTIME_PREFIX="VPDMN"
VCONTAINER_IMPORT_TARGET="containers-storage:"
VCONTAINER_STATE_FILE="podman-state.img"
VCONTAINER_OTHER_PREFIX="VDKR"
VCONTAINER_VERSION="1.2.0"

# Source common implementation
source "$(dirname "${BASH_SOURCE[0]}")/vcontainer-common.sh" "$@"

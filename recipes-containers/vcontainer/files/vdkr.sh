#!/bin/bash
# SPDX-FileCopyrightText: Copyright (C) 2025 Bruce Ashfield
#
# SPDX-License-Identifier: GPL-2.0-only
#
# vdkr: Docker-like interface for cross-architecture container operations
#
# This provides a familiar docker-like CLI that executes commands inside
# a QEMU-emulated environment with the target architecture's Docker.
#
# Command naming convention:
#   - Commands matching Docker's syntax/semantics use Docker's name (import, load, save, etc.)
#   - Extended commands with non-Docker behavior use 'v' prefix (vimport)

# Set runtime-specific parameters before sourcing common code
VCONTAINER_RUNTIME_NAME="vdkr"
VCONTAINER_RUNTIME_CMD="docker"
VCONTAINER_RUNTIME_PREFIX="VDKR"
VCONTAINER_IMPORT_TARGET="docker-daemon:"
VCONTAINER_STATE_FILE="docker-state.img"
VCONTAINER_OTHER_PREFIX="VPDMN"
VCONTAINER_VERSION="3.4.0"

# Source common implementation
source "$(dirname "${BASH_SOURCE[0]}")/vcontainer-common.sh" "$@"

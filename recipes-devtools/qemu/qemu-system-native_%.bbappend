# SPDX-FileCopyrightText: Copyright (C) 2025 Bruce Ashfield
#
# SPDX-License-Identifier: MIT
#
# Enable virtfs (virtio-9p) for vcontainer cross-architecture container bundling.
# This is required for the fast batch-import path in container-cross-install.
#
# Note: Native recipes don't see target DISTRO_FEATURES directly.
# The layer.conf propagates virtualization to DISTRO_FEATURES_NATIVE when
# vcontainer or virtualization is in the target DISTRO_FEATURES.

PACKAGECONFIG:append = " ${@bb.utils.contains('DISTRO_FEATURES_NATIVE', 'virtualization', 'virtfs', '', d)}"

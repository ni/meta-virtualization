# SPDX-FileCopyrightText: Copyright (C) 2025 Bruce Ashfield
#
# SPDX-License-Identifier: MIT
#
# container-registry-populate.bb
# ===========================================================================
# Push OCI container images from deploy directory to a container registry
# ===========================================================================
#
# This recipe discovers OCI images in DEPLOY_DIR_IMAGE and pushes them
# to the configured container registry using skopeo.
#
# Usage:
#   # Set registry URL (default: localhost:5000)
#   CONTAINER_REGISTRY_URL = "localhost:5000"
#
#   # Push all discovered images
#   bitbake container-registry-populate
#
#   # Push specific images only
#   CONTAINER_REGISTRY_IMAGES = "container-base container-app"
#   bitbake container-registry-populate
#
# Prerequisites:
#   - docker-distribution-native built and running
#   - Container images built (bitbake container-base)
#
# ===========================================================================

SUMMARY = "Push container images to registry"
DESCRIPTION = "Discovers OCI images in the deploy directory and pushes them \
to the configured container registry using skopeo. Works with docker-distribution, \
Docker Hub, or any OCI-compliant registry."

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit container-registry

# Additional dependencies
DEPENDS += "docker-distribution-native"

# Specific images to push (empty = auto-discover all)
CONTAINER_REGISTRY_IMAGES ?= ""

# Work directory
S = "${WORKDIR}/sources"

do_unpack[noexec] = "1"
do_patch[noexec] = "1"
do_configure[noexec] = "1"
do_compile[noexec] = "1"
do_install[noexec] = "1"

python do_populate_registry() {
    """Push OCI images to the configured registry."""
    import os

    registry = d.getVar('CONTAINER_REGISTRY_URL')
    namespace = d.getVar('CONTAINER_REGISTRY_NAMESPACE')
    specific_images = (d.getVar('CONTAINER_REGISTRY_IMAGES') or '').split()

    bb.note(f"Container Registry: {registry}/{namespace}/")
    bb.note(f"Tag Strategy: {d.getVar('CONTAINER_REGISTRY_TAG_STRATEGY')}")

    # Discover OCI images
    all_images = container_registry_discover_oci_images(d)

    if not all_images:
        bb.warn("No OCI images found in deploy directory")
        bb.note(f"Deploy directory: {d.getVar('DEPLOY_DIR_IMAGE')}")
        bb.note("Build container images first: bitbake container-base")
        return

    bb.note(f"Discovered {len(all_images)} OCI images")

    # Filter if specific images requested
    if specific_images:
        images = [(path, name) for path, name in all_images if name in specific_images]
        if not images:
            bb.warn(f"None of the requested images found: {specific_images}")
            bb.note(f"Available images: {[name for _, name in all_images]}")
            return
    else:
        images = all_images

    # Push each image
    pushed_refs = []
    for oci_path, image_name in images:
        bb.note(f"Processing: {image_name} from {oci_path}")
        refs = container_registry_push(d, oci_path, image_name)
        pushed_refs.extend(refs)

    # Summary
    bb.note("=" * 60)
    bb.note(f"Pushed {len(pushed_refs)} image references:")
    for ref in pushed_refs:
        bb.note(f"  {ref}")
    bb.note("=" * 60)
}

# Run after prepare_recipe_sysroot so skopeo-native is available
addtask populate_registry after do_prepare_recipe_sysroot before do_build

# Allow network access for pushing to registry
do_populate_registry[network] = "1"

# Don't cache - always push fresh
do_populate_registry[nostamp] = "1"

# Copyright (C) 2024-2025 Savoir-faire Linux, Inc

SUMMARY = "Cockpit UI for virtual machines"
DESCRIPTION = "Cockpit-machines provides a user interface to manage virtual machines"

BUGTRACKER = "github.com/cockpit-project/cockpit-machines/issues"

LICENSE = "LGPL-2.1-only"
LIC_FILES_CHKSUM = "file://LICENSE;md5=4fbd65380cdd255951079008b364516c"

DEPENDS += "cockpit"

SRC_URI = "https://github.com/cockpit-project/cockpit-machines/releases/download/${PV}/cockpit-machines-${PV}.tar.xz"
SRC_URI[sha256sum] = "c9d80357da2bf3ecda9698f0dc6fcb46675b3b76da9150a22178071fe982fcb0"

S = "${WORKDIR}/${PN}"

inherit autotools-brokensep features_check gettext

# systemd, which cockpit is dependent, is not compatible with musl lib
COMPATIBLE_HOST:libc-musl = "null"

RDEPENDS:${PN} += "cockpit libvirt-dbus pciutils virt-manager-install"

REQUIRED_DISTRO_FEATURES = "systemd pam"

# Default installation path of cockpit-machines is /usr/local/
FILES:${PN} = "\
    ${prefix}/local/ \
    ${datadir}/metainfo/org.cockpit-project.cockpit-machines.metainfo.xml \
"

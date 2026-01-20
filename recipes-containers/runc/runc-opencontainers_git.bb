include runc.inc

SRCREV = "4774df387790afbddcd2fd905d70ecb8aec9c341"
SRC_URI = " \
    git://github.com/opencontainers/runc;branch=release-1.2;protocol=https \
    file://0001-Makefile-respect-GOBUILDFLAGS-for-runc-and-remove-re.patch \
    "
RUNC_VERSION = "1.2.7"

CVE_PRODUCT = "runc"

LDFLAGS += "${@bb.utils.contains('DISTRO_FEATURES', 'ld-is-gold', ' -fuse-ld=bfd', '', d)}"

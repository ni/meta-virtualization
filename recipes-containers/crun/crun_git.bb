DESCRIPTION = "A fast and low-memory footprint OCI Container Runtime fully written in C."
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=b234ee4d69f5fce4486a80fdaf4a4263"
PRIORITY = "optional"

SRCREV_crun = "64611d7ac938b8397e8a00a0e69987583fadec7d"
SRCREV_libocispec = "552ccbbad3aaff8e07e8fbad210ec3b4c9c95a66"
SRCREV_ispec = "6519a62d628ec31b5da156de745b516d8850c8e3"
SRCREV_rspec = "5610abdb9fac3b48b2c0ba6216d77320cbbbfb6f"
SRCREV_yajl = "f344d21280c3e4094919fd318bc5ce75da91fc06"

SRCREV_FORMAT = "crun_rspec"
SRC_URI = "git://github.com/containers/crun.git;branch=main;name=crun;protocol=https \
           git://github.com/containers/libocispec.git;branch=main;name=libocispec;destsuffix=${BB_GIT_DEFAULT_DESTSUFFIX}/libocispec;protocol=https \
           git://github.com/opencontainers/runtime-spec.git;branch=main;name=rspec;destsuffix=${BB_GIT_DEFAULT_DESTSUFFIX}/libocispec/runtime-spec;protocol=https \
           git://github.com/opencontainers/image-spec.git;branch=main;name=ispec;destsuffix=${BB_GIT_DEFAULT_DESTSUFFIX}/libocispec/image-spec;protocol=https \
           git://github.com/containers/yajl.git;branch=main;name=yajl;destsuffix=${BB_GIT_DEFAULT_DESTSUFFIX}/libocispec/yajl;protocol=https \
           file://0001-libocispec-correctly-parse-JSON-schema-references.patch;patchdir=libocispec \
           file://0002-libocispec-fix-array-items-parsing.patch;patchdir=libocispec \
          "

PV = "v1.24.0+git"

inherit autotools-brokensep pkgconfig

# if this is true, we'll symlink crun to runc for easier integration
# with container stacks
CRUN_AS_RUNC ?= "true"

PACKAGECONFIG ??= " \
    caps external-yajl man \
    ${@bb.utils.contains('DISTRO_FEATURES', 'seccomp', 'seccomp', '', d)} \
    ${@bb.utils.contains('DISTRO_FEATURES', 'systemd', 'systemd', '', d)} \
"

PACKAGECONFIG[caps] = "--enable-caps,--disable-caps,libcap"
PACKAGECONFIG[external-yajl] = "--disable-embedded-yajl,--enable-embedded-yajl,yajl"
# whether to regenerate manpages that are already present in the repo
PACKAGECONFIG[man] = ",,go-md2man-native"
PACKAGECONFIG[seccomp] = "--enable-seccomp,--disable-seccomp,libseccomp"
PACKAGECONFIG[systemd] = "--enable-systemd,--disable-systemd,systemd"

DEPENDS = "m4-native"
DEPENDS:append:libc-musl = " argp-standalone"

do_configure:prepend () {
    # extracted from autogen.sh in crun source. This avoids
    # git submodule fetching.
    mkdir -p m4
    autoreconf -fi
}

do_install() {
    oe_runmake 'DESTDIR=${D}' install
    if [ -n "${CRUN_AS_RUNC}" ]; then
        ln -sr "${D}/${bindir}/crun" "${D}${bindir}/runc"
    fi
}

# When crun provides /usr/bin/runc symlink, it conflicts with the runc package
RCONFLICTS:${PN} = "${@'runc' if d.getVar('CRUN_AS_RUNC') else ''}"

REQUIRED_DISTRO_FEATURES:class-native ?= ""
DEPENDS:class-native += "yajl libcap go-md2man m4 libseccomp"
BBCLASSEXTEND = "native"

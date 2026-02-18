SUMMARY = "Production-Grade Container Scheduling and Management"
DESCRIPTION = "Lightweight Kubernetes, intended to be a fully compliant Kubernetes."
HOMEPAGE = "https://k3s.io/"
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${S}/src/import/LICENSE;md5=2ee41112a44fe7014dce33e26468ba93"

SRC_URI = "git://github.com/rancher/k3s.git;branch=release-1.34;name=k3s;protocol=https;destsuffix=${GO_SRCURI_DESTSUFFIX} \
           file://k3s.service \
           file://k3s-agent.service \
           file://k3s-agent \
           file://k3s-clean \
           file://cni-containerd-net.conf \
           file://0001-Finding-host-local-in-usr-libexec.patch;patchdir=src/import \
           file://k3s-killall.sh \
          "

SRC_URI[k3s.md5sum] = "363d3a08dc0b72ba6e6577964f6e94a5"
SRCREV_k3s = "54f28d21a6208b1f8f9c33e14cf1fc65c2030107"

SRCREV_FORMAT = "k3s_fuse"
PV = "v1.34.1+k3s1+git"

CNI_NETWORKING_FILES ?= "${UNPACKDIR}/cni-containerd-net.conf"

# Build tags - used by both do_compile and do_discover_modules
TAGS = "static_build netcgo osusergo providerless"

# go-mod-discovery configuration
# Uses defaults: SRCDIR=${S}/src/import, BUILD_TAGS=${TAGS}, GOPATH=${S}/src/import/.gopath:...
GO_MOD_DISCOVERY_BUILD_TARGET = "./cmd/server/main.go"
GO_MOD_DISCOVERY_LDFLAGS = "-X github.com/k3s-io/k3s/pkg/version.Version=${PV} -w -s"
GO_MOD_DISCOVERY_GIT_REPO = "https://github.com/rancher/k3s.git"
GO_MOD_DISCOVERY_GIT_REF = "${SRCREV_k3s}"

# GO_MOD_FETCH_MODE: "vcs" (all git://) or "hybrid" (gomod:// + git://)
GO_MOD_FETCH_MODE ?= "hybrid"

# VCS mode: all modules via git://
include ${@ "go-mod-git.inc" if d.getVar("GO_MOD_FETCH_MODE") == "vcs" else ""}
include ${@ "go-mod-cache.inc" if d.getVar("GO_MOD_FETCH_MODE") == "vcs" else ""}

# Hybrid mode: gomod:// for most, git:// for selected
include ${@ "go-mod-hybrid-gomod.inc" if d.getVar("GO_MOD_FETCH_MODE") == "hybrid" else ""}
include ${@ "go-mod-hybrid-git.inc" if d.getVar("GO_MOD_FETCH_MODE") == "hybrid" else ""}
include ${@ "go-mod-hybrid-cache.inc" if d.getVar("GO_MOD_FETCH_MODE") == "hybrid" else ""}

inherit go
inherit goarch
inherit systemd
inherit cni_networking
inherit go-mod-discovery

BB_GIT_SHALLOW = "1"

COMPATIBLE_HOST = "^(?!mips).*"

PACKAGECONFIG = ""
PACKAGECONFIG[upx] = ",,upx-native"
GO_IMPORT = "import"
GO_BUILD_LDFLAGS = "-X github.com/k3s-io/k3s/pkg/version.Version=${PV} \
                    -X github.com/k3s-io/k3s/pkg/version.GitCommit=${@d.getVar('SRCREV_k3s', d, 1)[:8]} \
                    -w -s \
                   "
BIN_PREFIX ?= "${exec_prefix}/local"

inherit features_check
REQUIRED_DISTRO_FEATURES ?= "seccomp"

DEPENDS += "rsync-native"

# Go's PIE builds pull in cgo objects that still require text relocations.
# Explicitly allow them at link time to avoid ld --fatal-warnings aborting the build.
GO_EXTRA_LDFLAGS:append = " -Wl,-z,notext"

do_compile() {
        export GOPATH="${S}/src/import/.gopath:${S}/src/import/vendor:${STAGING_DIR_TARGET}/${prefix}/local/go"
        export GOMODCACHE="${S}/pkg/mod"
        export CGO_ENABLED="1"
        export GOSUMDB="off"
        export GOTOOLCHAIN="local"
        export GOPROXY="off"

        # Remove go.sum files from git-fetched dependencies to prevent checksum conflicts
        # Our git-built modules have different checksums than proxy.golang.org tarballs
        find ${WORKDIR}/sources/vcs_cache -name "go.sum" -delete || true

        cd ${S}/src/import

        # go.mod and go.sum are synchronized by do_sync_go_files task
        # No manual fixes needed - discovery and recipe generation handle version matching

        VERSION_GOLANG="$(go version | cut -d" " -f3)"
        ${GO} build -trimpath -tags "${TAGS}" -ldflags "-X github.com/k3s-io/k3s/pkg/version.UpstreamGolang=$VERSION_GOLANG  ${GO_BUILD_LDFLAGS} -w -s" -o ./dist/artifacts/k3s ./cmd/server/main.go

        # Use UPX if it is enabled (and thus exists) to compress binary
        if command -v upx > /dev/null 2>&1; then
                upx -9 ./dist/artifacts/k3s
        fi
}

do_install() {
        install -d "${D}${BIN_PREFIX}/bin"
        install -m 755 "${S}/src/import/dist/artifacts/k3s" "${D}${BIN_PREFIX}/bin"
        ln -sr "${D}/${BIN_PREFIX}/bin/k3s" "${D}${BIN_PREFIX}/bin/crictl"
        # We want to use the containerd provided ctr
        # ln -sr "${D}/${BIN_PREFIX}/bin/k3s" "${D}${BIN_PREFIX}/bin/ctr"
        ln -sr "${D}/${BIN_PREFIX}/bin/k3s" "${D}${BIN_PREFIX}/bin/kubectl"
        install -m 755 "${UNPACKDIR}/k3s-clean" "${D}${BIN_PREFIX}/bin"
        install -m 755 "${UNPACKDIR}/k3s-killall.sh" "${D}${BIN_PREFIX}/bin"

        if ${@bb.utils.contains('DISTRO_FEATURES','systemd','true','false',d)}; then
                install -D -m 0644 "${UNPACKDIR}/k3s.service" "${D}${systemd_system_unitdir}/k3s.service"
                install -D -m 0644 "${UNPACKDIR}/k3s-agent.service" "${D}${systemd_system_unitdir}/k3s-agent.service"
                sed -i "s#\(Exec\)\(.*\)=\(.*\)\(k3s\)#\1\2=${BIN_PREFIX}/bin/\4#g" "${D}${systemd_system_unitdir}/k3s.service" "${D}${systemd_system_unitdir}/k3s-agent.service"
                install -m 755 "${UNPACKDIR}/k3s-agent" "${D}${BIN_PREFIX}/bin"
        fi

	mkdir -p ${D}${datadir}/k3s/
	install -m 0755 ${S}/src/import/contrib/util/check-config.sh ${D}${datadir}/k3s/
}

PACKAGES =+ "${PN}-server ${PN}-agent"

SYSTEMD_PACKAGES = "${@bb.utils.contains('DISTRO_FEATURES','systemd','${PN}-server ${PN}-agent','',d)}"
SYSTEMD_SERVICE:${PN}-server = "${@bb.utils.contains('DISTRO_FEATURES','systemd','k3s.service','',d)}"
SYSTEMD_SERVICE:${PN}-agent = "${@bb.utils.contains('DISTRO_FEATURES','systemd','k3s-agent.service','',d)}"
SYSTEMD_AUTO_ENABLE:${PN}-agent = "disable"

FILES:${PN}-agent = "${BIN_PREFIX}/bin/k3s-agent"
FILES:${PN} += "${BIN_PREFIX}/bin/*"

RDEPENDS:${PN} = "k3s-cni conntrack-tools coreutils findutils iptables iproute2 ipset virtual-containerd"
RDEPENDS:${PN}-server = "${PN}"
RDEPENDS:${PN}-agent = "${PN}"

RRECOMMENDS:${PN} = "\
                     kernel-module-xt-addrtype \
                     kernel-module-xt-nat \
                     kernel-module-xt-multiport \
                     kernel-module-xt-conntrack \
                     kernel-module-xt-comment \
                     kernel-module-xt-mark \
                     kernel-module-xt-connmark \
                     kernel-module-vxlan \
                     kernel-module-xt-masquerade \
                     kernel-module-xt-statistic \
                     kernel-module-xt-physdev \
                     kernel-module-xt-nflog \
                     kernel-module-xt-limit \
                     kernel-module-nfnetlink-log \
                     kernel-module-ip-vs \
                     kernel-module-ip-vs-rr \
                     kernel-module-ip-vs-sh \
                     kernel-module-ip-vs-wrr \
                     "

RCONFLICTS:${PN} = "kubectl"

PACKAGES =+ "${PN}-contrib"
FILES:${PN}-contrib += "${datadir}/k3s/check-config.sh"
RDEPENDS:${PN}-contrib += "bash"

INHIBIT_PACKAGE_STRIP = "1"
INSANE_SKIP:${PN} += "ldflags already-stripped textrel"

#
# Copyright (C) 2015 Wind River Systems, Inc.
#

require irqbalance.inc

SRCREV = "4c234853d5ac9f13d8fe6b618d41a44161de509b"
PV = "1.9.4+git"

SRC_URI = "git://github.com/Irqbalance/irqbalance;branch=master;protocol=https \
           file://add-initscript.patch \
           file://irqbalance-Add-status-and-reload-commands.patch \
          "

CFLAGS += "-Wno-error=format-security"

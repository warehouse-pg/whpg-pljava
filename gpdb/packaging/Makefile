mkrelease: gppkg

SHELL=/bin/bash

PGXS := $(shell pg_config --pgxs)
include $(PGXS)

# GP_MAJORVERSION is defined in lib/postgresql/pgxs/src/Makefile.global
GP_VERSION_NUM := $(GP_MAJORVERSION)
export GP_VERSION_NUM 

OS=$(word 1,$(subst _, ,$(BLDARCH)))
ARCH=x86_64
export OS
export ARCH

PLJAVA_DIR=$(shell cd ../.. && pwd)
export PLJAVA_DIR
include $(PLJAVA_DIR)/release.mk

PLJAVA_GPPKG:=pljava-$(PLJAVA_PIVOTAL_VERSION)-gp$(GP_VERSION_NUM)-$(OS)_$(ARCH).gppkg
export PLJAVA_GPPKG

# gppkg v2 is the format from 7X on; WHPG19 reports GP_MAJORVERSION=19.
ifeq ($(shell test -n '$(GP_MAJORVERSION)' && test '$(GP_MAJORVERSION)' -ge 7 && echo yes), yes)
include gppkg_v2.mk
else

ifneq (,$(findstring ubuntu,$(OS)))
include gppkg_deb.mk
else
include gppkg_rpm.mk
endif

endif
#
# Generic rules to build gppkgs included here
#

.PHONY: gppkg distro
gppkg: clean distro

.PHONY: cleanall
cleanall: clean

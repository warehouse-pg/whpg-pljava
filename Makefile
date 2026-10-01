#-------------------------------------------------------------------------
# Top level Makefile for PL/Java on WarehousePG 19 (upstream 1.6.x base).
#
# The 1.6 line is built with Maven (JDK 9+; pljava-pgxs drives the native
# build through pg_config) and installed by its own self-extracting jar, so
# the targets here wrap those rather than copying files by hand as the 1.5
# based `whpg` branch does.
#-------------------------------------------------------------------------

include release.mk

PROJDIR    := $(shell bash -c pwd)
PG_CONFIG  ?= pg_config
PGXS       := $(shell $(PG_CONFIG) --pgxs)
PGMAJOR    := $(shell $(PG_CONFIG) --version | sed -E 's/^PostgreSQL ([0-9]+).*/\1/')

# GPDB Makefile.global messes up JAVA_HOME
PLJAVA_HOME := $(JAVA_HOME)
include $(PGXS)
JAVA_HOME := $(PLJAVA_HOME)

sharedir   := $(shell $(PG_CONFIG) --sharedir)
PLJAVA_LIB := libpljava-so-$(PLJAVA_OSS_VERSION)
EXAMPLES_JAR := $(sharedir)/pljava/pljava-examples-$(PLJAVA_OSS_VERSION).jar
INSTALLER  := $(PROJDIR)/pljava-packaging/target/pljava-pg$(PGMAJOR).jar

# The server locates the JVM through this GUC in 1.6 (no LD_LIBRARY_PATH).
LIBJVM     ?= $(firstword $(wildcard $(JAVA_HOME)/lib/server/libjvm.so $(JAVA_HOME)/jre/lib/*/server/libjvm.so))

REGRESS_OPTS = --dbname=pljava_test --create-role=pljava_test
REGRESS = pljava_ext_init pljava_functions pljava_test pljava_ext_cleanup pljava_init pljava_functions pljava_test
REGRESS_DIR = $(top_builddir)

.DEFAULT_GOAL := build
.PHONY: build install uninstall test targetconfig targetcheck installcheck regress-sql show_java_version

# PL/Java 1.6 compiles with --release and needs JDK >= PLJAVA_MIN_JDK. If the
# JAVA_HOME we were handed is older (packaging images still default to 8), look
# for a newer JDK under /usr/lib/jvm before giving up with a clear message -
# javac's own complaint is only "invalid flag: --release".
jdk_major = $(shell '$(1)/bin/java' -version 2>&1 | sed -nE 's/^[a-z]+ version "(1\.)?([0-9]+).*/\2/p')
BUILD_JAVA_HOME := $(JAVA_HOME)
ifeq ($(shell test -n '$(JAVA_HOME)' && test '$(call jdk_major,$(JAVA_HOME))' -ge $(PLJAVA_MIN_JDK) 2>/dev/null && echo ok),)
BUILD_JAVA_HOME := $(firstword $(foreach v,$(PLJAVA_BUILD_JDK) 21 11,$(wildcard /usr/lib/jvm/java-$(v)-openjdk /usr/lib/jvm/java-$(v)-openjdk-*)))
endif

build:
	@test -n '$(BUILD_JAVA_HOME)' || { echo "PL/Java $(PLJAVA_OSS_VERSION) needs JDK $(PLJAVA_MIN_JDK)+ to build; JAVA_HOME=$(JAVA_HOME) is older and no newer JDK was found under /usr/lib/jvm" >&2; exit 1; }
	@echo "building with JAVA_HOME=$(BUILD_JAVA_HOME)"
	JAVA_HOME='$(BUILD_JAVA_HOME)' PATH='$(BUILD_JAVA_HOME)/bin:$(PATH)' mvn -B clean install

# `java -jar` installs through pg_config into pkglibdir/sharedir. With DESTDIR
# set it is given a pg_config wrapper that reports every path with the install
# prefix replaced by DESTDIR, so the result is laid out GPHOME-relative
# (lib/postgresql, share/postgresql, ...) - the shape a gppkg payload needs.
# GPDB's pg_config has no --prefix; derive it from --bindir. Assigned after the
# PGXS include on purpose: Makefile.global's prefix is the configure-time value,
# not where this installation actually lives.
prefix := $(patsubst %/bin,%,$(shell $(PG_CONFIG) --bindir))
install:
ifeq ($(DESTDIR),)
	java -jar '$(INSTALLER)'
else
	$(MKDIR_P) '$(DESTDIR)'
	printf '#!/bin/sh\nexec $(PG_CONFIG) "$$@" | sed "s|^$(prefix)|$(DESTDIR)|"\n' > '$(DESTDIR)/.pg_config' && chmod 755 '$(DESTDIR)/.pg_config'
	java -Dpgconfig='$(DESTDIR)/.pg_config' -jar '$(INSTALLER)'
	rm -f '$(DESTDIR)/.pg_config'
endif

uninstall:
	rm -f '$(pkglibdir)/$(PLJAVA_LIB)$(DLSUFFIX)'
	rm -rf '$(sharedir)/pljava'
	rm -f '$(sharedir)/extension/pljava.control' '$(sharedir)/extension/pljava--'*'.sql'

show_java_version:
	javac -version
	java -version
	echo JAVA_HOME=$(JAVA_HOME) LIBJVM=$(LIBJVM)

# The tests need the installed examples jar's path and the library name; pg_regress
# only substitutes its own @abs_*@ tokens, so the test scripts are generated here.
regress-sql:
	for t in pljava_ext_init pljava_init; do \
	  sed -e 's|@EXAMPLES_JAR@|$(EXAMPLES_JAR)|g' -e 's|@PLJAVA_LIB@|$(PLJAVA_LIB)|g' \
	      '$(PROJDIR)/gpdb/tests/templates/'$$t.source > '$(PROJDIR)/gpdb/tests/sql/'$$t.sql; done

test: show_java_version regress-sql
	sed -i '/.* # PLJAVA.*/d' $(MASTER_DATA_DIRECTORY)/pg_hba.conf
	echo 'host    all      pljava_test   0.0.0.0/0    trust # PLJAVA' >> $(MASTER_DATA_DIRECTORY)/pg_hba.conf
	echo 'local   all      pljava_test                trust # PLJAVA' >> $(MASTER_DATA_DIRECTORY)/pg_hba.conf
	gpstop -u
	cd $(PROJDIR)/gpdb/tests && $(REGRESS_DIR)/src/test/regress/pg_regress $(REGRESS_OPTS) $(REGRESS)

# Cluster-wide: tell the server where libjvm.so is. Needs a restart to apply.
# On Java 18 and later PL/Java 1.6 refuses to load unless the JVM is started
# with -Djava.security.manager=allow (JEP 411); enforcement itself works through
# Java 23. Set or clear pljava.vmoptions to match the runtime JDK.
JAVA_MAJOR := $(shell '$(JAVA_HOME)/bin/java' -version 2>&1 | sed -nE 's/^[a-z]+ version "(1\.)?([0-9]+).*/\2/p')
targetconfig:
	test -n '$(LIBJVM)' || { echo "cannot find libjvm.so under JAVA_HOME=$(JAVA_HOME)"; exit 1; }
	gpconfig -c pljava.libjvm_location -v "'$(LIBJVM)'" --skipvalidation
	if [ '$(JAVA_MAJOR)' -ge 18 ] 2>/dev/null; then \
	  gpconfig -c pljava.vmoptions -v "'-Djava.security.manager=allow'" --skipvalidation; \
	else \
	  gpconfig -r pljava.vmoptions --skipvalidation >/dev/null 2>&1 || true; \
	fi

installcheck: test
targetcheck: targetconfig test

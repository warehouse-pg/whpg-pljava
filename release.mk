PLJAVA_OSS_VERSION = 1.6.10
# PL/Java 1.6 needs Java 9+ to build; the lane builds with 17. Packaging specs
# should read this rather than hard-code a JDK.
PLJAVA_MIN_JDK = 9
PLJAVA_BUILD_JDK = 17

mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
current_dir := $(dir $(mkfile_path))
PLJAVA_PIVOTAL_VERSION = $(shell cat $(current_dir)VERSION)

PLJAVA_PIVOTAL_RELEASE = 0

#!/bin/bash -l

set -ex

source "$CI_REPO_DIR/common/entry_common.sh"
source "$(dirname "$0")/common.sh"

# PL/Java 1.6 needs Java 9+; build with the JDK named in release.mk
install_java 17
setup_maven

{
    # Needed by gppkg Makefile
    echo "export BLDARCH=\"${OS_NAME}_x86_64\""
} >>/home/gpadmin/.bashrc

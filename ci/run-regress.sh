#!/bin/bash
#
# Build PL/Java against an installed WarehousePG and run the gpdb regression
# suite (gpdb/tests) against a running cluster.
#
# Everything this needs is either in the image built from ci/Dockerfile or
# passed in below - there is no manual "dnf install java / maven" step, which
# is the whole point of this script existing. See ci/README.md.
#
# Environment:
#   GPHOME       WarehousePG install to build and test against
#                (default /usr/local/whpg)
#   SRC_DIR      whpg-pljava checkout (default: the repo this script is in)
#   BUILD_JDK    JDK to build with (default 8). Only 8 works today: the
#                top-level pom.xml compiles -source/-target 1.6 against
#                $JAVA_HOME/jre/lib/rt.jar, which JDK 9+ has neither of.
#   RUNTIME_JDK  JDK the server loads libjvm from (default $BUILD_JDK).
#                8, 11 and 17 pass the suite; 21 needs
#                pljava_vmoptions=-Djava.security.manager=allow and still has
#                CLDR locale diffs in the expected output.
#   TEST_JAVA_VERSION
#                JDK for `make examples`; defaults to $RUNTIME_JDK
#   GPDEMO_SRC   gpAux/gpdemo from the server source tree. If set and no
#                cluster is running, a demo cluster is created.
#   DEMO_DIR     where to put that cluster (default /home/gpadmin/gpdemo)
#   NUM_SEGMENTS primary segments for a created cluster (default 3)
#   RUN_MPP      if non-empty, also run ci/mpp-signal-check.sh against the same
#                cluster once the suite has passed
#
set -eo pipefail

GPHOME=${GPHOME:-/usr/local/whpg}
SRC_DIR=${SRC_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
BUILD_JDK=${BUILD_JDK:-${JDK:-8}}
RUNTIME_JDK=${RUNTIME_JDK:-$BUILD_JDK}
TEST_JAVA_VERSION=${TEST_JAVA_VERSION:-$RUNTIME_JDK}
DEMO_DIR=${DEMO_DIR:-/home/gpadmin/gpdemo}
NUM_SEGMENTS=${NUM_SEGMENTS:-3}

log() { printf '\n=== %s ===\n' "$*"; }

# --- JDK selection --------------------------------------------------------
# The rpm layout is java-1.8.0-openjdk for 8 and java-<n>-openjdk from 9 on.
jdk_home() {
    if [ "$1" = "8" ]; then echo /usr/lib/jvm/java-1.8.0-openjdk
    else echo "/usr/lib/jvm/java-$1-openjdk"; fi
}
BUILD_JAVA_HOME=$(jdk_home "$BUILD_JDK")
RUNTIME_JAVA_HOME=$(jdk_home "$RUNTIME_JDK")
for h in "$BUILD_JAVA_HOME" "$RUNTIME_JAVA_HOME"; do
    [ -x "$h/bin/javac" ] || {
        echo "No JDK compiler at $h - is the image built from ci/Dockerfile?" >&2
        exit 1
    }
done
export JAVA_HOME=$BUILD_JAVA_HOME
export PATH=$JAVA_HOME/bin:$PATH

# nar-maven-plugin 3.2.3 predates aarch64: its AOL table only knows amd64 and
# arm, so on any other arch the build dies looking up "<arch>.Linux.linker".
# The host compiler still emits correct native code either way - only the
# plugin's internal directory and classifier naming is affected - and the
# top-level Makefile already hardcodes amd64 in the path it copies the .so
# from, so normalise it here rather than at every call site.
export MAVEN_OPTS="-Dos.arch=amd64 ${MAVEN_OPTS:-}"

# shellcheck disable=SC1090,SC1091
source "$GPHOME/greenplum_path.sh"

log "toolchain"
java -version 2>&1
mvn -version 2>&1 | head -1
pg_config --version
echo "BUILD_JDK=$BUILD_JDK RUNTIME_JDK=$RUNTIME_JDK TEST_JAVA_VERSION=$TEST_JAVA_VERSION arch=$(uname -m)"

# --- cluster --------------------------------------------------------------
if [ -z "$MASTER_DATA_DIRECTORY" ] && [ -n "$GPDEMO_SRC" ]; then
    if [ ! -d "$DEMO_DIR/datadirs" ]; then
        log "creating $NUM_SEGMENTS-segment demo cluster in $DEMO_DIR"
        mkdir -p "$DEMO_DIR"
        cp -r "$GPDEMO_SRC"/. "$DEMO_DIR"/
        ( cd "$DEMO_DIR" \
          && NUM_PRIMARY_MIRROR_PAIRS=$NUM_SEGMENTS WITH_MIRRORS=false make cluster )
    fi
    # shellcheck disable=SC1090,SC1091
    source "$DEMO_DIR/gpdemo-env.sh"

    # gpdemo's Makefile does not propagate a gpinitsystem failure, so check
    # that we actually have a cluster rather than discovering it later in a
    # confusing gpstop error.
    if ! psql -X -qtA -d postgres -c 'select 1' >/dev/null 2>&1; then
        echo "demo cluster was not created - see the gpinitsystem output above" >&2
        exit 1
    fi
fi

: "${MASTER_DATA_DIRECTORY:=$COORDINATOR_DATA_DIRECTORY}"
export MASTER_DATA_DIRECTORY
export COORDINATOR_DATA_DIRECTORY=$MASTER_DATA_DIRECTORY
[ -n "$MASTER_DATA_DIRECTORY" ] || { echo "no cluster: set MASTER_DATA_DIRECTORY or GPDEMO_SRC" >&2; exit 1; }
export PGPORT=${PGPORT:-$(sed -n 4p "$MASTER_DATA_DIRECTORY/postmaster.pid")}
echo "MASTER_DATA_DIRECTORY=$MASTER_DATA_DIRECTORY PGPORT=$PGPORT"

# --- build and install ----------------------------------------------------
cd "$SRC_DIR"
log "make build"
make build
log "make install"
make install

# The JVM is found through $GPHOME/etc/environment.d/30-pljava.conf, which
# `make install` puts there. Deliberately do not export LD_LIBRARY_PATH by
# hand: re-sourcing greenplum_path.sh is what a real deployment does, and if
# the conf did not install this run must fail rather than paper over it.
export JAVA_HOME=$RUNTIME_JAVA_HOME
export PATH=$JAVA_HOME/bin:$PATH
unset LD_LIBRARY_PATH
# shellcheck disable=SC1090,SC1091
source "$GPHOME/greenplum_path.sh"
log "JVM path supplied by 30-pljava.conf (runtime JDK $RUNTIME_JDK)"
echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
case "$LD_LIBRARY_PATH" in
    *"$JAVA_HOME"*) ;;
    *) echo "30-pljava.conf did not contribute a JVM path - see Makefile installconfs" >&2
       exit 1 ;;
esac

log "restarting cluster so the postmaster inherits the JVM path"
gpstop -arf
sleep 3

# --- test -----------------------------------------------------------------
if [ "$TEST_JAVA_VERSION" != "$BUILD_JDK" ]; then
    log "make examples with JDK $TEST_JAVA_VERSION"
    make examples TEST_JAVA_VERSION="$TEST_JAVA_VERSION"
fi

log "make targetcheck"
rc=0
make targetcheck || rc=$?
if [ "$rc" -ne 0 ] && [ -f gpdb/tests/regression.diffs ]; then
    log "regression.diffs"
    cat gpdb/tests/regression.diffs
fi
log "targetcheck exit $rc"
[ "$rc" -eq 0 ] || exit "$rc"

# The MPP check needs a live cluster with pljava installed and
# pljava_classpath configured, which is exactly the state targetcheck leaves
# behind - so it has to run here rather than in a container of its own.
if [ -n "$RUN_MPP" ]; then
    log "MPP signal-safety check"
    "$SRC_DIR/ci/mpp-signal-check.sh"
    rc=$?
fi
exit "$rc"

#!/bin/bash
#
# Build PL/Java against an installed WarehousePG and run the gpdb regression
# suite (gpdb/tests) against a running cluster.
#
# Everything this needs is either in the image built from ci/Dockerfile or
# passed in below - there is no manual "dnf install java / maven" step, which
# is the whole point of this script existing. Lives under gpdb/ci because upstream already has a CI/ directory,
# and case-insensitive filesystems merge the two.
#
# Environment:
#   GPHOME       WarehousePG install to build and test against
#                (default /usr/local/whpg)
#   SRC_DIR      whpg-pljava checkout (default: the repo this script is in)
#   BUILD_JDK    JDK to build with (default 17). PL/Java 1.6 needs Java 9+.
#   RUNTIME_JDK  JDK the server loads libjvm from (default $BUILD_JDK); set
#                through pljava.libjvm_location. Policy enforcement works on
#                Java 9 through 23 (JEP 411/486), so 24+ is not a target.
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
SRC_DIR=${SRC_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
BUILD_JDK=${BUILD_JDK:-${JDK:-17}}
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
        echo "No JDK compiler at $h - is the image built from gpdb/ci/Dockerfile?" >&2
        exit 1
    }
done
export JAVA_HOME=$BUILD_JAVA_HOME
export PATH=$JAVA_HOME/bin:$PATH


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

# 1.6 locates the JVM through the pljava.libjvm_location GUC, not through
# LD_LIBRARY_PATH; `make targetconfig` sets it from JAVA_HOME. Switch JAVA_HOME
# to the runtime JDK first so that is the libjvm the server is pointed at.
export JAVA_HOME=$RUNTIME_JAVA_HOME
export PATH=$JAVA_HOME/bin:$PATH
log "pointing the server at the runtime JVM (runtime JDK $RUNTIME_JDK)"
make targetconfig
gpconfig -s pljava.libjvm_location | grep -i "value" || { echo "pljava.libjvm_location not set" >&2; exit 1; }

log "restarting cluster so the postmaster inherits the JVM path"
gpstop -arf
sleep 3

# --- test -----------------------------------------------------------------
log "make test"
rc=0
make test || rc=$?
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
    "$SRC_DIR/gpdb/ci/mpp-signal-check.sh"
    rc=$?
fi
exit "$rc"

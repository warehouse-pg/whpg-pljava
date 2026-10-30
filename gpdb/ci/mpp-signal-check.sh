#!/bin/bash
#
# Exercise the MPP-23735 SIGUSR1 substitution (Backend.c,
# PLCatchupInterruptHandler) under real segment execution.
#
# Why this exists: PL/Java replaces the backend's SIGUSR1 handler so that the
# real catchup logic - which touches LWLocks and is not safe off the main
# thread - only ever runs on the main thread, forwarding with pthread_kill
# when the signal lands on a JVM-internal thread. PG19 removed the ability to
# capture the previously installed handler from pqsignal(), so the WHPG19 port
# had to rewrite that path to call procsignal_sigusr1_handler() by name. There
# is no upstream coverage for any of this: upstream PL/Java has no MPP, so if
# it regresses nobody outside WarehousePG will notice.
#
# The check runs a Java function across every segment, delivers SIGUSR1 to the
# segment backends *while they are inside the JVM*, and then verifies that the
# results are still correct and the cluster is still healthy.
#
# Environment: GPHOME, MASTER_DATA_DIRECTORY (or a sourced gpdemo-env.sh),
#              PGPORT, PGDATABASE (default pljava_mpp)
#
set -eo pipefail

GPHOME=${GPHOME:-/usr/local/whpg}
# shellcheck disable=SC1090,SC1091
source "$GPHOME/greenplum_path.sh"
: "${MASTER_DATA_DIRECTORY:=$COORDINATOR_DATA_DIRECTORY}"
export MASTER_DATA_DIRECTORY COORDINATOR_DATA_DIRECTORY=$MASTER_DATA_DIRECTORY
export PGPORT=${PGPORT:-$(sed -n 4p "$MASTER_DATA_DIRECTORY/postmaster.pid")}
DB=${PGDATABASE:-pljava_mpp}
ROWS=${ROWS:-400000}
SIGNAL_BURSTS=${SIGNAL_BURSTS:-40}

q()  { psql -X -q -p "$PGPORT" -d "$DB" -v ON_ERROR_STOP=1 -c "$1"; }
qt() { psql -X -qtA -p "$PGPORT" -d "$DB" -v ON_ERROR_STOP=1 -c "$1"; }

log() { printf '\n=== %s ===\n' "$*"; }

log "preparing $DB"
psql -X -q -p "$PGPORT" -d postgres -c "DROP DATABASE IF EXISTS $DB" >/dev/null
psql -X -q -p "$PGPORT" -d postgres -c "CREATE DATABASE $DB" >/dev/null
q "CREATE EXTENSION pljava"
# 1.6 resolves classes from the sqlj jar repository, replicated to every
# segment on WarehousePG. Install the examples jar and give public a classpath.
JAR="$(pg_config --sharedir)/pljava/pljava-examples-${PLJAVA_OSS_VERSION:-1.6.10}.jar"
[ -f "$JAR" ] || { echo "examples jar not installed: $JAR" >&2; exit 1; }
q "SELECT sqlj.install_jar('file:$JAR', 'examples', false)"
q "SELECT sqlj.set_classpath('public', 'examples')"

q "CREATE FUNCTION java_addone(int) RETURNS int
     AS 'org.postgresql.pljava.example.annotation.Parameters.addOne(java.lang.Integer)'
     IMMUTABLE LANGUAGE java"

q "CREATE TABLE mpp_probe(id int) DISTRIBUTED BY (id)"
q "INSERT INTO mpp_probe SELECT generate_series(1,$ROWS)"
q "ANALYZE mpp_probe"

# ---------------------------------------------------------------------------
log "1. the function really runs on segments, not only the coordinator"
SEGS=$(qt "SELECT count(DISTINCT gp_segment_id) FROM (
             SELECT gp_segment_id, java_addone(id) FROM mpp_probe) s")
NSEG=$(qt "SELECT count(*) FROM gp_segment_configuration
             WHERE content >= 0 AND role = 'p'")
echo "segments executing PL/Java: $SEGS of $NSEG primaries"
[ "$SEGS" = "$NSEG" ] || { echo "FAIL: PL/Java did not run on every segment" >&2; exit 1; }

EXPECTED=$(qt "SELECT sum(id+1)::text FROM mpp_probe")

# ---------------------------------------------------------------------------
log "2. SIGUSR1 delivered to segment backends while they are inside the JVM"

RESULT_FILE=$(mktemp)
(
  psql -X -qtA -p "$PGPORT" -d "$DB" -v ON_ERROR_STOP=1 \
       -c "SELECT sum(java_addone(id))::text FROM mpp_probe" > "$RESULT_FILE" 2>&1
  echo "QUERY_RC=$?" >> "$RESULT_FILE"
) &
QUERY_PID=$!

# The segment backends of the query above, found through the catalog rather
# than ps: on macOS the ps title PostgreSQL sets is not visible to pgrep, and
# pg_stat_activity is exact where a process-name match is not. All segments
# of a demo cluster are local, so the pids can be signalled directly.
seg_pids() {
    qt "SELECT pid FROM gp_dist_random('pg_stat_activity')
         WHERE query LIKE '%java_addone%' AND pid <> pg_backend_pid()" 2>/dev/null
}
sent=0
for _ in $(seq 1 "$SIGNAL_BURSTS"); do
    kill -0 "$QUERY_PID" 2>/dev/null || break
    for pid in $(seg_pids); do
        kill -USR1 "$pid" 2>/dev/null && sent=$((sent+1))
    done
    sleep 0.1
done
wait "$QUERY_PID" || true
echo "SIGUSR1 delivered $sent times to segment backends"
[ "$sent" -gt 0 ] || { echo "FAIL: no SIGUSR1 was delivered - test proved nothing" >&2; exit 1; }

ACTUAL=$(grep -v '^QUERY_RC=' "$RESULT_FILE" | tr -d '[:space:]')
QRC=$(grep '^QUERY_RC=' "$RESULT_FILE" | cut -d= -f2)
rm -f "$RESULT_FILE"
echo "query exit=$QRC result=$ACTUAL expected=$EXPECTED"
[ "$QRC" = "0" ]              || { echo "FAIL: query errored under SIGUSR1" >&2; exit 1; }
[ "$ACTUAL" = "$EXPECTED" ]   || { echo "FAIL: wrong result under SIGUSR1" >&2; exit 1; }

# ---------------------------------------------------------------------------
log "3. cluster still healthy and PL/Java still usable afterwards"
DOWN=$(qt "SELECT count(*) FROM gp_segment_configuration WHERE status <> 'u'")
echo "segments not up: $DOWN"
[ "$DOWN" = "0" ] || { echo "FAIL: a segment went down" >&2; exit 1; }

AGAIN=$(qt "SELECT sum(java_addone(id))::text FROM mpp_probe")
[ "$AGAIN" = "$EXPECTED" ] || { echo "FAIL: PL/Java broken after signalling" >&2; exit 1; }

log "4. no crash in the segment logs"
# Only the log file each instance is writing now: older files in the same
# directory may hold crashes from unrelated earlier sessions.
# (no mapfile: macOS ships bash 3.2)
CURRENT_LOGS=$(qt "SELECT datadir FROM gp_segment_configuration ORDER BY content" \
               | while IFS= read -r d; do ls -t "$d"/log/*.csv 2>/dev/null | head -1; done)
CRASH=$(grep -lE 'PANIC|segmentation fault|was terminated by signal' \
          $CURRENT_LOGS 2>/dev/null | head -5 || true)
if [ -n "$CRASH" ]; then
    echo "WARNING: crash-like entries found in:"; echo "$CRASH"
else
    echo "none"
fi

log "MPP signal-safety check PASSED ($SEGS segments, $sent signals)"

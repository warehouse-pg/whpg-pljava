# CI for whpg-pljava

`whpg` is a single multi-line branch: the WHPG19 adaptation is guarded on
`PG_VERSION_NUM` rather than living on its own branch, so every change has to
keep building on WarehousePG 7 (PG12) *and* WHPG19 (PG19). Nothing enforced
that until now, and the branch had in fact stopped compiling on PG12.

What is here:

| file | what it is |
| --- | --- |
| `Dockerfile` | build image definition - adds the JVM toolchain the shared WarehousePG build image does not carry |
| `entrypoint.sh` | starts `sshd` (gpdemo drives segments over ssh) |
| `run-regress.sh` | build + install + run `gpdb/tests` against a running cluster |
| `../.github/workflows/whpg19-regress.yml` | the WHPG19 lane, JDK 8/11/17/21 |

## Why the image definition exists

PL/Java is the only extension in the set that needs a JVM toolchain, and
`ghcr.io/warehouse-pg/whpg-rocky9-build` (checked 2026-08-04) does not carry a
complete one:

* maven and the JDK 11 / JDK 17 **devel** packages are present;
* JDK 8 is present as the **headless runtime only** - `rt.jar` and `libjvm.so`
  but no `javac`. `concourse/pre_build.sh` pins the native build to JDK 8
  ("Use jdk8 to build always") because the top-level `pom.xml` compiles with
  `-bootclasspath $JAVA_HOME/jre/lib/rt.jar`, so a build in that image fails
  unless CI installs `java-1.8.0-openjdk-devel` at runtime;
* JDK 21 is absent entirely.

`ci/Dockerfile` installs all four `-devel` packages plus maven, so the JDK
matrix is reproducible from the image alone with no runtime `dnf install`.

## Reproducing a run locally

The workflow needs a container image that carries an installed WarehousePG 19
at `$GPHOME` plus `gpAux/gpdemo`. No such image is published yet - that is the
one piece still missing from this lane. Until it is, the same run can be done
by hand from any WHPG19 install:

```sh
# 1. build the image. BASE_IMAGE can be the shared build image, or a bare
#    distro - the package list is complete either way.
docker build -f ci/Dockerfile --build-arg BASE_IMAGE=rockylinux:9 \
             -t whpg-pljava-build:local .

docker run -d --name pljava-ci --hostname pljava-ci \
           whpg-pljava-build:local sleep infinity

# 2. drop a WHPG19 install at /usr/local/whpg and gpAux/gpdemo at /opt/gpdemo,
#    both owned by gpadmin, and this checkout at /home/gpadmin/pljava_src.

# 3. run it. Creates a 3-segment demo cluster on first use.
#    BUILD_JDK is 8 because only JDK 8 can build this tree; RUNTIME_JDK is the
#    JVM the server loads. RUN_MPP also runs ci/mpp-signal-check.sh afterwards.
docker exec -u gpadmin pljava-ci env \
    GPHOME=/usr/local/whpg GPDEMO_SRC=/opt/gpdemo \
    SRC_DIR=/home/gpadmin/pljava_src \
    BUILD_JDK=8 RUNTIME_JDK=8 RUN_MPP=1 \
    /home/gpadmin/pljava_src/ci/run-regress.sh
```

Expected: `All 7 tests passed.` and no `gpdb/tests/regression.diffs`.

`run-regress.sh` deliberately drops `LD_LIBRARY_PATH` before starting the
cluster and re-sources `greenplum_path.sh`, so the JVM can only be found via
the `30-pljava.conf` that `make install` writes to
`$GPHOME/etc/environment.d`. If that conf is not installed the run fails
instead of quietly passing on a hand-exported path - which is how the
`installconfs` gate came to be skipped on WHPG19 unnoticed.

## JDK matrix

Only JDK 8 builds this tree: the top-level `pom.xml` compiles
`-source/-target 1.6` against `$JAVA_HOME/jre/lib/rt.jar`, and JDK 9+ has
neither. At run time the server can load JDK 8, 11 or 17 (all 7/7). JDK 21
needs `pljava_vmoptions=-Djava.security.manager=allow`, because PL/Java 1.5's
trusted-language sandbox uses `SecurityManager`, which JDK 18+ disables by
default; after that the only remaining failures are CLDR locale differences in
the expected output.

## Arch note

`nar-maven-plugin` 3.2.3 predates aarch64 and has no `aarch64.Linux.linker`
entry in its AOL table. `run-regress.sh` sets `-Dos.arch=amd64`, which only
affects the plugin's internal directory and classifier naming - the host
compiler still emits correct native code - and matches the `amd64` path the
top-level `Makefile` copies the built `.so` from. Real CI runs on x86_64 where
this is a no-op.

# Build/test image for whpg-pljava.
#
# By default this layers on the shared WarehousePG build image and adds what
# PL/Java needs on top of it. The package list is deliberately complete rather
# than "only the diff against the shared image", so the same file also produces
# a working image from a bare distro:
#
#     docker build -f ci/Dockerfile --build-arg BASE_IMAGE=rockylinux:9 .
#
# which is what ci/README.md uses to reproduce a run locally.
#
# Why this file has to exist at all: PL/Java is the only extension in the set
# that needs a JVM toolchain, and the shared build image does not carry a
# complete one.  As of ghcr.io/warehouse-pg/whpg-rocky9-build (2026-08-04):
#
#   * maven and the JDK 11 / JDK 17 *devel* packages are present;
#   * JDK 8 is present as the *headless runtime only* - it ships rt.jar and
#     libjvm.so but no javac.  concourse/pre_build.sh requires a JDK 8
#     *compiler* ("Use jdk8 to build always") because the top-level pom.xml
#     compiles with -bootclasspath $JAVA_HOME/jre/lib/rt.jar, so a build in
#     that image fails unless CI installs java-1.8.0-openjdk-devel at runtime;
#   * JDK 21 is absent entirely.
#
# Installing the four devel packages explicitly is what makes the JDK matrix in
# .github/workflows/whpg19-regress.yml reproducible from the image alone.

ARG BASE_IMAGE=ghcr.io/warehouse-pg/whpg-rocky9-build:latest
FROM ${BASE_IMAGE}

# The JVM toolchain. See the note above for why JDK 8 devel in particular is
# not optional.
RUN dnf install -y \
        java-1.8.0-openjdk-devel \
        java-11-openjdk-devel \
        java-17-openjdk-devel \
        java-21-openjdk-devel \
        maven \
    && dnf clean all && rm -rf /var/cache/dnf/*

# Native build toolchain plus the runtime libraries the WarehousePG server
# binaries link against (derived from `ldd .../bin/postgres`), and the handful
# of utilities gpdemo / gpstart / pg_regress shell out to. gpstop and gpstart
# are Python and import psycopg2 and psutil from the system, not from
# $GPHOME/lib/python, so those packages are part of the runtime too.
# gpinitsystem shells out to ping, ping6, ip and ss during its host checks and
# exits FATAL without them, so iputils and iproute are required to create a
# cluster at all. WarehousePG's pg_regress is not stock: it compares output
# through gpdiff.pl, so perl (plus Data::Dumper and FindBin) is what makes the
# regression suite runnable, not an optional extra. gcc-c++ is not
# optional: nar-maven-plugin drives the native build through its "gpp" linker
# (the AOL is amd64-Linux-gpp), and without g++ it fails with a bare
# NullPointerException rather than anything that names the missing tool.
# These are all no-ops on the shared build image; they are what makes a
# bare-distro base usable.
RUN dnf install -y \
        gcc gcc-c++ make \
        diffutils file findutils gzip tar which hostname procps-ng rsync \
        iputils iproute net-tools lsof \
        perl perl-Data-Dumper perl-FindBin perl-File-Temp perl-Getopt-Long perl-IO \
        openssh-server openssh-clients \
        python3 python3-psycopg2 python3-psutil python3-pyyaml \
        glibc-langpack-en \
        krb5-libs libxml2 openssl-libs pcre2 xz-libs zlib keyutils-libs \
        libcom_err libselinux \
    && dnf clean all && rm -rf /var/cache/dnf/*

# Headers pulled in transitively by the installed server headers. WarehousePG
# is configured --with-gssapi --with-libxml --with-openssl, and those options
# leak into the public headers an extension compiles against: libpq/pg-gssapi.h
# includes <gssapi/gssapi.h>, so without krb5-devel the PL/Java native build
# fails on a header it never asked for.
RUN dnf install -y \
        krb5-devel libxml2-devel openssl-devel zlib-devel readline-devel \
    && dnf clean all && rm -rf /var/cache/dnf/*

# gpdemo drives the segments over ssh, so the test user needs to be able to
# reach localhost without a prompt.
RUN id gpadmin >/dev/null 2>&1 || useradd -m -s /bin/bash gpadmin; \
    mkdir -p /home/gpadmin/.ssh && chmod 700 /home/gpadmin/.ssh; \
    ssh-keygen -t rsa -N '' -f /home/gpadmin/.ssh/id_rsa -q; \
    cp /home/gpadmin/.ssh/id_rsa.pub /home/gpadmin/.ssh/authorized_keys; \
    chmod 600 /home/gpadmin/.ssh/authorized_keys; \
    printf 'StrictHostKeyChecking no\nUserKnownHostsFile /dev/null\nLogLevel ERROR\n' \
        > /home/gpadmin/.ssh/config; \
    chmod 600 /home/gpadmin/.ssh/config; \
    chown -R gpadmin:gpadmin /home/gpadmin/.ssh; \
    ssh-keygen -A

COPY ci/entrypoint.sh /usr/local/bin/pljava-ci-entrypoint
RUN chmod 755 /usr/local/bin/pljava-ci-entrypoint

ENTRYPOINT ["/usr/local/bin/pljava-ci-entrypoint"]
CMD ["bash"]

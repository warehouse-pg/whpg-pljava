# WarehousePG PL/Java

## Introduction

PL/Java is a free add-on module that brings Java stored procedures, triggers,
and functions to the backend of a distributed database like WarehousePG.
Functions are written as static Java methods, packaged in jar files, and run
inside a JVM in each database process, with access to the database through a
JDBC-compatible interface.

This repository is a fork of the open-source Greenplum PL/Java project
(github.com/greenplum-db/pljava-archive), renamed to whpg-pljava and maintained
for WarehousePG.

It is based on PL/Java 1.5.0, originally forked from
https://github.com/tada/pljava/tree/V1_5_0.

## Requirements

* WarehousePG, with its `pg_config` on your `PATH`
* JDK 8 or later
* Maven

The trusted `java` language is sandboxed by the Java SecurityManager. It works
on JDK 17 or earlier, and on JDK 18 to 23 only with
`-Djava.security.manager=allow` in `pljava_vmoptions`. On later JDKs trusted
functions fail with an error; the untrusted `javaU` language does not need the
SecurityManager.

## Building and Testing

```
make                 # build with Maven
make install         # install into the WarehousePG installation
make installcheck    # run the regression tests in gpdb/tests
```

`make installcheck` needs a running WarehousePG cluster.

## Versioning

The PL/Java source version (`PLJAVA_OSS_VERSION` in `release.mk`) is 1.5.0.
The package version, used for the gppkg, rpm, and deb packages, is kept in the
`VERSION` file. Besides adding a new git tag, bump `VERSION` when making a
release.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and the
[Code of Conduct](CODE-OF-CONDUCT.md). To report a security issue, see
[SECURITY.md](SECURITY.md).

## License

BSD 3-Clause. See [LICENSE.md](LICENSE.md).

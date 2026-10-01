-- cleanup schema and functions used by `create extension pljava`
DROP SCHEMA IF EXISTS javatest CASCADE;
DROP EXTENSION pljava;
-- leave no trace of the extension install so the LOAD-path cycle that follows
-- starts from nothing (sqlj may survive DROP EXTENSION when it holds jar rows)
DROP SCHEMA IF EXISTS sqlj CASCADE;

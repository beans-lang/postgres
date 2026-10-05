# Changelog

## Unreleased

- Generate Linux glibc x86_64 and macOS x86_64 headers from pinned PostgreSQL
  18.0 with executed configure probes; compile and execute the vendored C
  on each target. Beans package execution is a separate acceptance gate.
- Pass the full PostgreSQL gate on Linux glibc x86_64 with a rebuilt
  unreleased Beans 0.1.51 / ABI 22 compiler: four server suites in both
  backends, platform selectors, target checks, and DI integration. The Linux
  interpreter requires that checkout's hosted-registry fix; 0.1.50 native
  suites pass, but its interpreter cannot resolve `beans_fiber_wait_io`.
- Select configuration by explicit OS/architecture and refuse unsupported
  Windows, other architectures, and unconfigured musl builds.
- Add C preprocessing gates and a reproducible configuration generator;
  discover the sibling compiler in the documented workspace layout.

## 0.1.0

First release. PostgreSQL over vendored libpq 18.0, TLS off.

- 44 vendored translation units, at their upstream paths, with per-platform
  `configure` output behind three marked relay headers.
- `Connection.open` drives libpq's non-blocking connect and parks the fiber on
  every wait libpq asks for.
- `query` / `execute` / `query_one` / `query_value` / `execute_script`, with
  `$1` parameters bound out of band.
- Typed columns by OID: bool, the integer family, floats with `Infinity` and
  `NaN`, exact `numeric`, `bytea` in both input spellings, json, uuid, and the
  common array types.
- Transactions with all three isolation levels, savepoints, and a closure form
  that rolls back on any failure.
- Prepared statements with a per-connection cache capped at 128.
- LISTEN / NOTIFY with a per-call timeout that parks the fiber, and
  notifications drained from every query.
- Pipelining, COPY IN and COPY OUT.
- `Pool` over `dbcore.Pool`, and `postgres_di` for barista.

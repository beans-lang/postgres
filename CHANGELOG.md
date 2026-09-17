# Changelog

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

# postgres for Beans

A PostgreSQL driver built on **vendored libpq**, driven as a state machine so
every wait parks a Beans fiber instead of blocking a thread.

```beans
import github.com/beans-lang/postgres
import github.com/beans-lang/dbcore

let db: postgres.Connection = postgres.Connection.open(
    postgres.Config.at("127.0.0.1", 5432, "beans", "beansdb")
        .with_password("beans"))?

let rows: dbcore.ResultSet =
    db.query("select id, email from users where id = $1",
             [dbcore.Value.of_int(7)])?
io.println(rows.row(0).text("email"))
```

No system libpq to install, no `make` step, no prebuilt binary. The C compiles
with your program on the configured platforms below.

---

## Install

```
# beans.pot
require github.com/beans-lang/postgres v0.1.0
require github.com/beans-lang/dbcore v0.1.0
```

The platform configuration and selector changes described below are unreleased
checkout changes; the published `v0.1.0` package does not include them.

Working inside the `beans-lang` workspace instead of from a published tag?
These four packages depend on each other by path there, which is what their
own `beans.pot` files use:

```
require path "../dbcore"
```

Native builds need **beansc 0.1.46 or newer**. Four `cflags` rows name directories
inside this package, and before 0.1.46 a relative include path resolved
against the build's working directory instead — so libpq would not compile.
On Linux, the interpreter needs the **unreleased 0.1.51 checkout's**
hosted-registry fix for `beans_fiber_wait_io`; the published 0.1.50 interpreter
cannot resolve that runtime function. Both backends passed with the rebuilt
0.1.51 / ABI 22 Linux
compiler; native Linux 0.1.50 execution was tested separately.

Needs a C compiler — which `beansc` already needs for any native build, and
also under `beansc run`, where the vendored C is compiled once into a cached
shared library.

| platform | state |
|---|---|
| macOS arm64 | **supported**, tested against `postgres:18` |
| Linux aarch64 (glibc) | existing configuration and prior PostgreSQL 18 test record; this 0.1.51 verification did not rerun aarch64 |
| Linux x86_64 (glibc) | both backends tested with unreleased Beans 0.1.51 / ABI 22 against `postgres:18`; four suites match the same goldens |
| macOS x86_64 | generated configuration; vendored C authenticated and queried under Rosetta; Beans has no macOS x86_64 target |
| Linux musl | no validated musl configuration; C compilation refuses rather than reusing glibc headers |
| Windows | incomplete port: configuration, Windows C sources and link selection need validation |

A platform without validated configuration stops at a `#error` naming it.
Relays match both OS and architecture; an unknown architecture never inherits
x86_64 headers, and iOS never inherits macOS headers. Type checking alone does
not compile vendored C. See
`vendor/VENDOR.md` and `tools/configure_platform.sh` for reproducible generation.
Windows also needs platform-specific sources and native integration tests.

---

## Why libpq, and what that costs

25 years of fixed bugs in wire framing, SCRAM, cancellation and COPY are worth
more than a fresh implementation. A pure-Beans Postgres is blocked besides:
`caching`-free SCRAM needs no TLS, but the protocol's in-band TLS upgrade has
no `std.tls` client API yet, and `scram-sha-256-plus` needs peer-certificate
access Beans does not expose.

The cost is one rule that shapes everything:

> **libpq can never call back into Beans.** The toolchain links a package's C
> into a shared library with no `-undefined dynamic_lookup`, so a vendored
> `.c` carrying an undefined `beans_*` symbol does not link at all.

So libpq is driven, never hooked. Its event system and every callback-shaped
API are out; every wait happens on the Beans side through `dbcore.wait`, and
the whole driver is `PQsend*` → `PQflush` → park → `PQconsumeInput` →
`PQgetResult`.

**TLS is not built in.** This package ships without OpenSSL, so `sslmode`
above `disable` fails at connect naming the reason. `scram-sha-256` still
works, because postgres's own SHA-2 is vendored — OpenSSL is needed for the
transport, never for the handshake. That makes a TLS-free build a real
local-development configuration rather than a broken one.

---

## Connecting

```beans
let config: postgres.Config =
    postgres.Config.at("db.internal", 5432, "app", "shop")
        .with_password(secret)
        .with_sslmode("disable")
        .with_application_name("checkout")
        .with_timeouts(10000, 30000)     // connect ms, statement ms
        .with_extra("target_session_attrs=read-write")
```

Values are quoted the way libpq quotes them, so a password with a space in it
stays one parameter. `with_extra` appends verbatim for anything not wrapped.

---

## Queries

```beans
db.query(sql, params)        // -> ResultSet
db.execute(sql, params)      // -> affected rows
db.query_one(sql, params)    // -> Option<Row>
db.query_value(sql, params)  // -> Value, the first cell
db.execute_script(sql)       // several statements, no parameters
```

**Parameters are `$1`, `$2`, … and never string interpolation.** They travel
out of band, so a value containing `'; drop table users; --` is a value.

### Types

Columns come back as typed `dbcore.Value`s, chosen by the column's OID:

| postgres | Value |
|---|---|
| `bool` | `bool_value` |
| `int2` `int4` `int8` `oid` | `int_value` — full 64-bit range |
| `float4` `float8` | `float_value`, including `Infinity` and `NaN` |
| `numeric` | `decimal_value` — **exact base-10 text, nothing rounds** |
| `text` `varchar` `bpchar` `name` | `text_value` |
| `bytea` | `bytes_value`, hex or escape input both decoded |
| `json` `jsonb` | `json_value` |
| `uuid` | `uuid_value` |
| `int4[]` `text[]` and the other listed array types | `array_value` |
| anything else | `text_value` — the server's own text |

Text wire format, not binary. Every type has an exact text form, `numeric`
survives it without rounding, and it is one decoder rather than one per OID
pair. Binary is a later optimisation; it lands when a benchmark says the
parse cost matters, and it changes no API.

---

## Transactions

```beans
db.begin(postgres.Isolation.serializable)?
db.execute("update accounts set balance = balance - $1 where id = $2", [...])?
db.commit()?
```

Or as a closure, which rolls back on **any** failure including a `?` that left
early:

```beans
db.transaction<int>(postgres.Isolation.serializable,
    fn() -> Result<int, dbcore.DbError> {
        db.execute("update accounts set balance = balance - 30 where id = 1")?
        return db.query_value("select balance from accounts where id = 1", [])
                 .map(fn(v: dbcore.Value) -> int { return v.as_int() })
    })?
```

Savepoints: `savepoint(name)`, `rollback_to(name)`, `release_savepoint(name)`.

**There is no rollback in `deinit`, on purpose.** `deinit` may not park and
`ROLLBACK` is a round trip, so a transaction left open marks its connection
dirty and the pool cleans it up on a call that *may* park. The closure form
above is the shape to reach for.

---

## Prepared statements

```beans
let plan: int = db.prepare("select * from users where id = $1")?
let rows: dbcore.ResultSet = db.query_prepared(plan, [dbcore.Value.of_int(7)])?
```

Preparing the same text twice answers the same handle. Names are
**per-connection**, so the cache lives on the `Connection` and never on the
`Pool`; the cache is capped at 128 and evicts with `DEALLOCATE`, so a program
building SQL in a loop cannot make the server hold unbounded plans.

---

## LISTEN / NOTIFY

```beans
listener.listen("orders")?
sender.notify("orders", "42")?          // pg_notify, so the channel is a value

match listener.next_notification(5000)? {
    some(note) => { io.println("{note.channel_name()} {note.body()}") }
    none       => { /* five seconds of quiet */ }
}
```

`next_notification` takes a **per-call** timeout and parks the fiber, so a
listener does not hold a worker thread. It ticks every 250 ms internally, so a
caller that wants to `listen` on one more channel gets its turn within a tick.

**A notification can arrive at any time, including between DataRows.** Every
query drains them into the same queue, so one that arrived behind a `select`
is not lost — `take_notifications()` collects them.

The reader is one fiber, and that is forced: a `Brew<T>` cannot be a field, so
a connection cannot own its reader, and one worker cannot park two fibers on
one descriptor. Brew it in the caller's scope.

---

## Pooling

```beans
let pool: postgres.Pool = postgres.Pool.open(config, 10)?

pool.query(sql, params)?
pool.execute(sql, params)?

// Multi-step work needs one connection for every step:
pool.with_connection<int>(fn(conn: postgres.Connection) -> Result<int, dbcore.DbError> {
    conn.begin(postgres.Isolation.read_committed)?
    conn.execute("insert into ledger values ($1)", [...])?
    let n: int = conn.query_value("select count(*) from ledger", [])?.as_int()
    conn.commit()?
    return ok(n)
})?
```

A full pool **parks** — backpressure, never loss. `try_with_connection`
refuses with `pool_exhausted` instead. The gate proves the overlap: eight
200 ms `pg_sleep` calls through three connections finish in under 1200 ms,
where a thread-blocking driver would take 1600.

With a container:

```beans
import github.com/beans-lang/postgres/di as postgres_di
postgres_di.add_postgres(services, config, 10)?
```

---

## Bulk paths

### Pipelining

```beans
let batch: postgres.Pipeline = new postgres.Pipeline()
batch.queue("select 1", [])
batch.queue("select $1::text", [dbcore.Value.of_text("two")])
let answers: postgres.PipelineResults = db.run_pipeline(batch)?
```

One round trip for the whole batch. The first failure ends it — postgres
aborts a pipeline at the first error and skips to the sync, so a later
statement never had an answer to give.

### COPY

```beans
db.copy_in("copy events (at, kind) from stdin")?
for row: string in rows { db.copy_send_text("{row}\n")? }
let taken: int = db.copy_finish()?

db.copy_out("copy (select * from events) to stdout")?
for {
    match db.copy_next()? {
        some(chunk) => { consume(chunk) }
        none        => { break }
    }
}
```

The gate round-trips 1000 rows in and reads them back.

---

## Errors

Every call answers `Result<T, dbcore.DbError>`. The kind comes from the
server's own SQLSTATE, which postgres promises never changes:

```beans
match db.execute(sql, params) {
    err(why) => {
        why.kind()        // "unique_violation"
        why.sqlstate()    // "23505"
        why.constraint()  // "users_email_key"
        why.detail()      // the server's DETAIL line
        why.is_retryable()
    }
    ok(n) => {}
}
```

A `DbError` crosses into a plain `Result<T>` through `?` on its own.

---

## What is not here

- **TLS.** No OpenSSL is linked. `sslmode` above `disable` fails at connect.
- **GSSAPI / Kerberos**, and **OAuth**. Both pull a second system dependency
  for a path almost no Beans user reaches; the refusal arrives at connect
  naming the method, never at build time.
- **Large objects.** `fe-lobj.c` is compiled but not surfaced; `bytea` covers
  the need. `SKIPPED.md` says what a real request would cost.
- **Unix sockets.** libpq supports them and `with_extra("host=/var/run/postgresql")`
  passes through, but CI is TCP-only, so they are untested rather than claimed.
- **Windows fiber concurrency.** There is no netpoller there, so a wait blocks
  its worker thread, exactly as every other Beans network client behaves on
  Windows.

---

## Tests

```bash
docker run -d --name beans_db_pg -p 55432:5432 \
  -e POSTGRES_USER=beans -e POSTGRES_PASSWORD=beans -e POSTGRES_DB=beansdb postgres:18
./test.sh --native
```

Four suites, both backends against the same golden files. Before them, a
vendor-integrity step: every relay header still carries its marker, every
configured platform has its three generated files, and every
`csrc` row names a file that exists — **hard failures, never skips**.
The C preprocessing gate checks four configured triples and refusal of six
unconfigured triples plus both supported-architecture musl triples.

A missing server is a hard failure too. It skips only when
`BEANS_DB_ALLOW_SKIP=1` is set on purpose, and a skipping run says plainly
that it proved nothing.

**Not covered yet:** a sanitizer leg, and a differential corpus against an
outside implementation. The suites here were written alongside the code, so
they check that it does what it was built to do — they are not an independent
answer sheet.

## Licences

- This package: MIT, `LICENSE`.
- Vendored libpq: the PostgreSQL License, `vendor/postgresql/COPYRIGHT`.

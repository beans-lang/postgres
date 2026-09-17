package main

import postgres
import github.com/beans-lang/dbcore
import std.io
import std.os
import std.time

fn config() -> postgres.Config {
    var port: int = 55432
    match os.env("BEANS_PG_PORT") {
        some(text) => { port = text.to_int().or(55432) }
        none => {}
    }
    return postgres.Config.at("127.0.0.1", port, "beans", "beansdb")
        .with_password("beans").with_sslmode("disable")
}

pub class Watch {
    in_flight: int = 0
    peak: int = 0
    pub fn init() {}
}

fn main() {
    let pool: postgres.Pool = postgres.Pool.open(config(), 3).expect("open")
    io.println("-- after open --")
    io.println(pool.stats().to_string())

    io.println("-- one query --")
    io.println("{pool.query_value("select 6 * 7", []).expect("q").as_int()}")
    io.println(pool.stats().to_string())

    io.println("-- a transaction needs one connection for every step --")
    let total: int = pool.with_connection<int>(
        fn(conn: postgres.Connection) -> Result<int, dbcore.DbError> {
            conn.execute_script("create temporary table t (n int)")?
            conn.begin(postgres.Isolation.read_committed)?
            conn.execute("insert into t values (1), (2), (3)", [])?
            let sum: int = conn.query_value("select sum(n) from t", [])?.as_int()
            conn.commit()?
            return ok(sum)
        }).expect("transaction")
    io.println("sum {total}")

    io.println("-- eight fibers through three connections --")
    let watch: Watch = new Watch()
    let started: int = time.monotonic_nanos()
    let answers: List<int> = run_eight(pool, watch)
    let elapsed: int = (time.monotonic_nanos() - started) / 1000000
    var sum: int = 0
    for value: int in answers { sum = sum + value }
    io.println("completed {answers.len()} sum {sum}")
    io.println("peak in flight {watch.peak} (max is 3)")
    io.println("never past the max {watch.peak <= 3}")
    io.println("more than one at once {watch.peak > 1}")
    io.println(pool.stats().to_string())

    io.println("-- and they really overlapped --")
    // Eight 200 ms server-side sleeps through three connections is three
    // rounds, about 600 ms. Serially it would be 1600.
    io.println("eight 200 ms sleeps took under 1200 ms {elapsed < 1200}")
    io.println("and at least one round {elapsed >= 400}")

    io.println("-- a failing query keeps the connection --")
    match pool.query("select * from no_such_table", []) {
        ok(_) => { io.println("unexpectedly ok") }
        err(why) => { io.println("{why.kind()} {why.sqlstate()}") }
    }
    io.println("still usable {pool.ping().expect("ping")}")
    io.println(pool.stats().to_string())

    io.println("-- exhaustion refuses rather than parks --")
    let refused: string = pool.with_connection<string>(
        fn(a: postgres.Connection) -> Result<string, dbcore.DbError> {
            return pool.with_connection<string>(
                fn(b: postgres.Connection) -> Result<string, dbcore.DbError> {
                    return pool.with_connection<string>(
                        fn(c: postgres.Connection) -> Result<string, dbcore.DbError> {
                            let fourth: Result<int, dbcore.DbError> =
                                pool.try_with_connection<int>(
                                    fn(d: postgres.Connection) -> Result<int, dbcore.DbError> {
                                        return ok(1)
                                    })
                            match fourth {
                                ok(n) => { return ok("unexpectedly ok {n}") }
                                err(why) => { return ok("{why.kind()}") }
                            }
                        })
                })
        }).expect("exhaustion")
    io.println(refused)

    io.println("-- close --")
    io.println("closed {pool.close().expect("close")}")
    match pool.ping() {
        ok(_) => { io.println("unexpectedly ok after close") }
        err(why) => { io.println("after close {why.kind()}") }
    }
}

fn run_eight(pool: postgres.Pool, watch: Watch) -> List<int> {
    var done: List<int> = []
    let a: Brew<int> = brew one(pool, watch)
    let b: Brew<int> = brew one(pool, watch)
    let c: Brew<int> = brew one(pool, watch)
    let d: Brew<int> = brew one(pool, watch)
    let e: Brew<int> = brew one(pool, watch)
    let f: Brew<int> = brew one(pool, watch)
    let g: Brew<int> = brew one(pool, watch)
    let h: Brew<int> = brew one(pool, watch)
    done.push(a.join().expect("a"))
    done.push(b.join().expect("b"))
    done.push(c.join().expect("c"))
    done.push(d.join().expect("d"))
    done.push(e.join().expect("e"))
    done.push(f.join().expect("f"))
    done.push(g.join().expect("g"))
    done.push(h.join().expect("h"))
    return move done
}

// pg_sleep runs on the server, so the fiber has nothing to do but park. That
// is the whole proof: a worker that blocked here would take 1600 ms.
fn one(pool: postgres.Pool, watch: Watch) -> int {
    return pool.with_connection<int>(
        fn(conn: postgres.Connection) -> Result<int, dbcore.DbError> {
            watch.in_flight = watch.in_flight + 1
            if watch.in_flight > watch.peak { watch.peak = watch.in_flight }
            conn.execute("select pg_sleep(0.2)", [])?
            watch.in_flight = watch.in_flight - 1
            return ok(1)
        }).or(0)
}

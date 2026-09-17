package main

import postgres
import github.com/beans-lang/dbcore
import std.io

// A pool shared by fibers. Six queries, three connections: the extra three
// wait rather than opening more, and the waits overlap.
fn main() {
    let config: postgres.Config =
        postgres.Config.at("127.0.0.1", 5432, "beans", "beansdb")
            .with_password("beans").with_sslmode("disable")
    let pool: postgres.Pool = postgres.Pool.open(config, 3).expect("open")

    let a: Brew<int> = brew work(pool, 1)
    let b: Brew<int> = brew work(pool, 2)
    let c: Brew<int> = brew work(pool, 3)
    let d: Brew<int> = brew work(pool, 4)
    let e: Brew<int> = brew work(pool, 5)
    let f: Brew<int> = brew work(pool, 6)

    var total: int = 0
    total = total + a.join().expect("a")
    total = total + b.join().expect("b")
    total = total + c.join().expect("c")
    total = total + d.join().expect("d")
    total = total + e.join().expect("e")
    total = total + f.join().expect("f")

    io.println("six queries answered {total}")
    io.println(pool.stats().to_string())
    pool.close().expect("close")
}

// Two steps on one connection, which is what `with_connection` is for.
fn work(pool: postgres.Pool, tag: int) -> int {
    return pool.with_connection<int>(
        fn(conn: postgres.Connection) -> Result<int, dbcore.DbError> {
            conn.execute("select pg_sleep(0.1)", [])?
            return conn.query_value("select $1::int4 * 2",
                                    [dbcore.Value.of_int(tag)])
                       .map(fn(v: dbcore.Value) -> int { return v.as_int() })
        }).or(0)
}

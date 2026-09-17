package main

import postgres
import github.com/beans-lang/dbcore
import std.io

// A short tour. Needs a local postgres — the README's docker line starts one.
fn main() {
    let config: postgres.Config =
        postgres.Config.at("127.0.0.1", 5432, "beans", "beansdb")
            .with_password("beans")
            .with_sslmode("disable")
            .with_application_name("tour")

    let db: postgres.Connection = postgres.Connection.open(config).expect("open")
    io.println("postgres {db.server_version()}, backend pid {db.backend_pid()}")

    db.execute_script("create table if not exists people (id serial primary key, name text not null, score numeric)")
        .expect("create")

    // Parameters are $1, $2 — never string interpolation.
    db.execute("insert into people (name, score) values ($1, $2)",
               [dbcore.Value.of_text("ada"), dbcore.Value.of_decimal("99.5")])
        .expect("insert")

    let rows: dbcore.ResultSet =
        db.query("select id, name, score from people order by id", []).expect("select")
    for row: dbcore.Row in rows.rows() {
        io.println("{row.int("id")} {row.text("name")} {row.get("score").as_text()}")
    }

    // A transaction that rolls back on any failure, including a `?`.
    let moved: Result<int, dbcore.DbError> = db.transaction<int>(
        postgres.Isolation.serializable,
        fn() -> Result<int, dbcore.DbError> {
            db.execute("update people set score = score + 1 where name = $1",
                       [dbcore.Value.of_text("ada")])?
            return db.query_value("select count(*) from people", []).map(
                fn(v: dbcore.Value) -> int { return v.as_int() })
        })
    io.println("people {moved.or(0)}")

    db.execute_script("drop table people").expect("drop")
    db.close().expect("close")
}

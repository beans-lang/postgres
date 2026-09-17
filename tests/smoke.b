package main

import postgres
import github.com/beans-lang/dbcore
import std.io
import std.os

fn config() -> postgres.Config {
    var port: int = 55432
    match os.env("BEANS_PG_PORT") {
        some(text) => { port = text.to_int().or(55432) }
        none => {}
    }
    return postgres.Config.at("127.0.0.1", port, "beans", "beansdb")
        .with_password("beans")
        .with_sslmode("disable")
        .with_application_name("beans-gate")
}

fn main() {
    let db: postgres.Connection = postgres.Connection.open(config()).expect("open")
    io.println("connected {db.is_live()}")
    io.println("server is at least 15 {db.server_version() >= 150000}")

    io.println("-- a scalar --")
    io.println("{db.query_value("select 1 + 1", []).expect("sum").to_string()}")

    io.println("-- typed columns --")
    let row: Result<dbcore.ResultSet, dbcore.DbError> = db.query(
        r"select true, 42::int4, 9223372036854775807::int8, 1.5::float8, 'hello'::text, '12345.6789'::numeric, '\x00ff41'::bytea, null::text",
        [])
    match row {
        ok(set) => { io.println(set.to_string()) }
        err(why) => { io.println("types failed {why.kind()}: {why.message()}") }
    }

    io.println("-- parameters --")
    let bound: dbcore.ResultSet = db.query(
        "select $1::int4 as n, $2::text as t, $3::bool as b, $4::numeric as d",
        [dbcore.Value.of_int(7), dbcore.Value.of_text("param"),
         dbcore.Value.of_bool(false), dbcore.Value.of_decimal("0.125")]
    ).expect("params")
    io.println(bound.to_string())

    io.println("-- a parameter is never SQL --")
    let evil: dbcore.ResultSet = db.query("select $1::text as t",
        [dbcore.Value.of_text("'; drop table users; --")]).expect("evil")
    io.println(evil.row(0).text("t"))

    db.close().expect("close")
    io.println("closed")
}

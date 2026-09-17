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
        .with_password("beans").with_sslmode("disable")
}

fn main() {
    let db: postgres.Connection = postgres.Connection.open(config()).expect("open")
    db.execute_script("drop table if exists beans_crud").expect("drop")
    db.execute_script(
        "create table beans_crud (id serial primary key, name text not null unique, score numeric, tags text[], note text)"
    ).expect("create")

    io.println("-- insert --")
    io.println("rows {db.execute("insert into beans_crud (name, score, tags, note) values ($1, $2, $3, $4)", [dbcore.Value.of_text("ada"), dbcore.Value.of_decimal("99.50"), dbcore.Value.of_array([dbcore.Value.of_text("x"), dbcore.Value.of_text("y,z")]), dbcore.Value.null()]).expect("insert")}")
    io.println("rows {db.execute("insert into beans_crud (name, score) values ($1, $2)", [dbcore.Value.of_text("grace"), dbcore.Value.of_decimal("-0.001")]).expect("insert")}")

    io.println("-- select --")
    let all: dbcore.ResultSet = db.query(
        "select id, name, score, tags, note from beans_crud order by id", []
    ).expect("select")
    io.println(all.to_string())
    io.println("column types {all.column(2).type_name()} {all.column(3).type_name()}")

    io.println("-- arrays round trip --")
    let tags: dbcore.Value = all.row(0).get("tags")
    io.println("count {tags.array_count()} first {tags.array_at(0).as_text()} second {tags.array_at(1).as_text()}")

    io.println("-- update and delete --")
    io.println("updated {db.execute("update beans_crud set score = $1 where name = $2", [dbcore.Value.of_decimal("1.25"), dbcore.Value.of_text("grace")]).expect("update")}")
    io.println("deleted {db.execute("delete from beans_crud where name = $1", [dbcore.Value.of_text("nobody")]).expect("delete")}")

    io.println("-- prepared --")
    let plan: int = db.prepare("select name from beans_crud where score > $1 order by name").expect("prepare")
    io.println("same text, same handle {db.prepare("select name from beans_crud where score > $1 order by name").expect("again") == plan}")
    let found: dbcore.ResultSet = db.query_prepared(plan, [dbcore.Value.of_decimal("1.0")]).expect("run")
    io.println(found.to_string())
    io.println("cached {db.prepared_count()}")

    io.println("-- errors from a real server --")
    for bad: List<string> in [["insert into beans_crud (name) values ('ada')", "unique"],
                              ["insert into beans_crud (name) values (null)", "not null"],
                              ["select * from nosuchtable", "missing table"],
                              ["select bad syntax here", "syntax"],
                              ["select 1/0", "division"]] {
        match db.execute(bad[0], []) {
            ok(n) => { io.println("{bad[1]} unexpectedly ok {n}") }
            err(why) => {
                io.println("{bad[1]} -> {why.kind()} sqlstate {why.sqlstate()} constraint '{why.constraint()}' retryable {why.is_retryable()}")
            }
        }
    }

    io.println("-- transactions --")
    db.begin(postgres.Isolation.serializable).expect("begin")
    db.execute("insert into beans_crud (name) values ($1)", [dbcore.Value.of_text("rolled")]).expect("insert")
    io.println("inside {db.query_value("select count(*) from beans_crud where name = 'rolled'", []).expect("count").as_int()}")
    db.rollback().expect("rollback")
    io.println("after rollback {db.query_value("select count(*) from beans_crud where name = 'rolled'", []).expect("count").as_int()}")

    db.begin(postgres.Isolation.read_committed).expect("begin")
    db.execute("insert into beans_crud (name) values ($1)", [dbcore.Value.of_text("kept")]).expect("insert")
    db.commit().expect("commit")
    io.println("after commit {db.query_value("select count(*) from beans_crud where name = 'kept'", []).expect("count").as_int()}")

    io.println("-- a closure transaction rolls back on a failure --")
    let attempt: Result<int, dbcore.DbError> = db.transaction<int>(
        postgres.Isolation.read_committed,
        fn() -> Result<int, dbcore.DbError> {
            db.execute("insert into beans_crud (name) values ($1)",
                       [dbcore.Value.of_text("doomed")])?
            return err(new dbcore.DbError(dbcore.KIND_SERVER, "the caller said no"))
        })
    match attempt {
        ok(n) => { io.println("unexpectedly ok {n}") }
        err(why) => { io.println("failed with {why.kind()}") }
    }
    io.println("doomed rows {db.query_value("select count(*) from beans_crud where name = 'doomed'", []).expect("count").as_int()}")
    io.println("in a transaction {db.is_in_transaction()}")

    io.println("-- savepoints --")
    db.begin(postgres.Isolation.read_committed).expect("begin")
    db.savepoint("sp1").expect("savepoint")
    db.execute("insert into beans_crud (name) values ($1)", [dbcore.Value.of_text("sp")]).expect("insert")
    db.rollback_to("sp1").expect("rollback to")
    db.commit().expect("commit")
    io.println("sp rows {db.query_value("select count(*) from beans_crud where name = 'sp'", []).expect("count").as_int()}")

    io.println("-- pipelining --")
    let batch: postgres.Pipeline = new postgres.Pipeline()
    batch.queue("select 1", [])
    batch.queue("select $1::text", [dbcore.Value.of_text("two")])
    batch.queue("select count(*) from beans_crud", [])
    let results: postgres.PipelineResults = db.run_pipeline(batch).expect("pipeline")
    io.println(results.to_string())

    io.println("-- COPY --")
    db.execute_script("create temporary table beans_copy (a int, b text)").expect("temp")
    db.copy_in("copy beans_copy (a, b) from stdin").expect("copy in")
    for index: int in 0..1000 {
        db.copy_send_text("{index}\trow {index}\n").expect("copy send")
    }
    io.println("copied {db.copy_finish().expect("copy finish")}")
    io.println("count {db.query_value("select count(*) from beans_copy", []).expect("count").as_int()}")
    io.println("sum {db.query_value("select sum(a) from beans_copy", []).expect("sum").as_int()}")

    db.copy_out("copy (select a, b from beans_copy order by a limit 3) to stdout").expect("copy out")
    var lines: int = 0
    for {
        match db.copy_next().expect("copy next") {
            some(chunk) => {
                io.println("  {chunk.to_string().trim()}")
                lines = lines + 1
            }
            none => { break }
        }
    }
    io.println("read {lines} rows back")

    db.execute_script("drop table if exists beans_crud").expect("cleanup")
    db.close().expect("close")
}

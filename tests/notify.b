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

fn main() {
    let listener: postgres.Connection = postgres.Connection.open(config()).expect("listener")
    let sender: postgres.Connection = postgres.Connection.open(config()).expect("sender")

    io.println("-- listen --")
    listener.listen("beans_events").expect("listen")
    listener.listen("other").expect("listen other")

    io.println("-- notify --")
    sender.notify("beans_events", "first").expect("notify")
    sender.notify("beans_events", "second").expect("notify")
    sender.notify("other", "elsewhere").expect("notify")

    var seen: int = 0
    for seen < 3 {
        match listener.next_notification(4000).expect("next") {
            some(note) => {
                io.println("  {note.to_string()} from another backend {note.sender_pid() != listener.backend_pid()}")
                seen = seen + 1
            }
            none => { io.println("  timed out with {seen} of 3"); break }
        }
    }

    io.println("-- a quiet channel times out rather than hanging --")
    let started: int = time.monotonic_nanos()
    match listener.next_notification(400).expect("quiet") {
        some(note) => { io.println("  unexpected {note.to_string()}") }
        none => { io.println("  none, as expected") }
    }
    let waited: int = (time.monotonic_nanos() - started) / 1000000
    io.println("  waited about 400 ms {waited >= 300 && waited < 2000}")

    io.println("-- unlisten --")
    listener.unlisten("beans_events").expect("unlisten")
    sender.notify("beans_events", "ignored").expect("notify")
    sender.notify("other", "still listening").expect("notify")
    match listener.next_notification(2000).expect("after unlisten") {
        some(note) => { io.println("  {note.to_string()}") }
        none => { io.println("  nothing arrived") }
    }

    io.println("-- a notification can arrive while a query runs --")
    listener.listen("beans_events").expect("relisten")
    sender.notify("beans_events", "during").expect("notify")
    let value: int = listener.query_value("select 41 + 1", []).expect("query").as_int()
    io.println("  query answered {value}")
    let queued: List<postgres.Notification> = listener.take_notifications()
    io.println("  and {queued.len()} notification was waiting behind it")
    for note: postgres.Notification in queued { io.println("  {note.to_string()}") }

    io.println("-- a fiber can wait on a notification --")
    let waiter: Brew<string> = brew wait_for(listener)
    time.sleep_nanos(80000000)
    sender.notify("beans_events", "late").expect("notify")
    io.println("  {waiter.join().expect("join")}")

    listener.close().expect("close listener")
    sender.close().expect("close sender")
}

fn wait_for(listener: postgres.Connection) -> string {
    match listener.next_notification(5000) {
        ok(found) => {
            match found {
                some(note) => { return note.to_string() }
                none => { return "timed out" }
            }
        }
        err(why) => { return "error {why.kind()}" }
    }
}

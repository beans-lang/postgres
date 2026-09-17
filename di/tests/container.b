package main

import github.com/beans-lang/barista
import postgres
import postgres_di
import std.io

fn main() {
    let services: barista.ServiceCollection = new barista.ServiceCollection()
    postgres_di.add_postgres(services,
        postgres.Config.at("127.0.0.1", 5432, "beans", "beansdb"), 4)
        .expect("register")
    io.println("registered")
}

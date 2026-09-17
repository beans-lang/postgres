// Postgres for Beans — the connection.
//
// libpq is driven as a state machine: every wait happens on the Beans side,
// through `dbcore.wait`. That is not a preference. A vendored `.c` cannot
// reference a `beans_*` symbol (the toolchain links its shared library with
// no `-undefined dynamic_lookup`), so libpq can never call back into us —
// which rules out its event system and any callback-shaped API.
package postgres

import github.com/beans-lang/dbcore
import github.com/beans-lang/dbcore/wait
import postgres.sys

// libpq spells these as #defines and enums, which a generated binding cannot
// see. Restated from libpq-fe.h; postgres does not renumber them.
pub const CONNECTION_OK: int = 0
pub const CONNECTION_BAD: int = 1
pub const POLLING_FAILED: int = 0
pub const POLLING_READING: int = 1
pub const POLLING_WRITING: int = 2
pub const POLLING_OK: int = 3

pub const PGRES_EMPTY_QUERY: int = 0
pub const PGRES_COMMAND_OK: int = 1
pub const PGRES_TUPLES_OK: int = 2
pub const PGRES_COPY_OUT: int = 3
pub const PGRES_COPY_IN: int = 4
pub const PGRES_BAD_RESPONSE: int = 5
pub const PGRES_NONFATAL_ERROR: int = 6
pub const PGRES_FATAL_ERROR: int = 7
pub const PGRES_COPY_BOTH: int = 8
pub const PGRES_SINGLE_TUPLE: int = 9
pub const PGRES_PIPELINE_SYNC: int = 10
pub const PGRES_PIPELINE_ABORTED: int = 11

// PG_DIAG_* field codes, the single characters PQresultErrorField takes.
const DIAG_SQLSTATE: int = 67
const DIAG_MESSAGE_PRIMARY: int = 77
const DIAG_MESSAGE_DETAIL: int = 68
const DIAG_MESSAGE_HINT: int = 72
const DIAG_CONSTRAINT_NAME: int = 110

pub enum Isolation {
    read_committed,
    repeatable_read,
    serializable
}

pub fn isolation_sql(level: Isolation) -> string {
    match level {
        read_committed => { return "READ COMMITTED" }
        repeatable_read => { return "REPEATABLE READ" }
        serializable => { return "SERIALIZABLE" }
    }
}

pub class Config {
    host: string = "127.0.0.1"
    port: int = 5432
    user: string = "postgres"
    password: string = ""
    database: string = ""
    application_name: string = "beans"
    sslmode: string = "prefer"
    connect_timeout_ms: int = 10000
    statement_timeout_ms: int = 0
    extra: string = ""

    pub fn init() {}

    pub static fn at(host: string, port: int, user: string,
                     database: string) -> Config {
        let config: Config = new Config()
        config.host = host
        config.port = port
        config.user = user
        config.database = database
        return config
    }

    pub fn with_password(password: string) -> Config {
        self.password = password
        return self
    }

    /// `disable`, `allow`, `prefer`, `require`, `verify-ca`, `verify-full`.
    /// Anything but `disable` needs a libpq built with OpenSSL; this package
    /// ships without it, so a TLS request fails at connect naming the reason.
    pub fn with_sslmode(mode: string) -> Config {
        self.sslmode = mode
        return self
    }

    pub fn with_application_name(name: string) -> Config {
        self.application_name = name
        return self
    }

    pub fn with_timeouts(connect_ms: int, statement_ms: int) -> Config {
        self.connect_timeout_ms = connect_ms
        self.statement_timeout_ms = statement_ms
        return self
    }

    /// Extra `key=value` pairs appended verbatim to the connection string.
    pub fn with_extra(text: string) -> Config {
        self.extra = text
        return self
    }

    pub fn address() -> string { return "{self.host}:{self.port}" }

    /// The libpq conninfo string. Values are single-quoted with backslash
    /// escapes, which is libpq's own quoting rule — a password with a space
    /// in it is otherwise two parameters.
    pub fn conninfo() -> string {
        var out: string = "host={quote(self.host)} port={self.port}"
        out = "{out} user={quote(self.user)}"
        if self.password != "" { out = "{out} password={quote(self.password)}" }
        if self.database != "" { out = "{out} dbname={quote(self.database)}" }
        if self.application_name != "" {
            out = "{out} application_name={quote(self.application_name)}"
        }
        out = "{out} sslmode={quote(self.sslmode)}"
        if self.connect_timeout_ms > 0 {
            var seconds: int = self.connect_timeout_ms / 1000
            if seconds < 1 { seconds = 1 }
            out = "{out} connect_timeout={seconds}"
        }
        if self.statement_timeout_ms > 0 {
            out = "{out} options='-c statement_timeout={self.statement_timeout_ms}'"
        }
        if self.extra != "" { out = "{out} {self.extra}" }
        return out
    }
}

fn quote(value: string) -> string {
    var out: string = "'"
    for index: int in 0..value.len() {
        let piece: string = value.slice(index, index + 1)
        if piece == "'" || piece == "\\" { out = "{out}\\" }
        out = "{out}{piece}"
    }
    return "{out}'"
}

// ---- C text helpers ----

fn c_text(text: string) -> Bytes {
    var buffer: Bytes = Bytes.from(text)
    buffer.push(0)
    return move buffer
}

// Beans keeps u8 and i8 pointers distinct; the C ABI does not.
fn as_char_ptr(pointer: RawPtr<u8>) -> RawPtr<i8> {
    unsafe { return RawPtr.from_address(pointer.address()) }
}

// Every text crossing the boundary is copied out at once, so no Beans value
// depends on C-owned memory after this returns.
fn read_c_text(pointer: RawPtr<i8>) -> string {
    if pointer.is_null() { return "" }
    var length: int = 0
    unsafe {
        let view: RawPtr<u8> = RawPtr.from_address(pointer.address())
        for (view.offset(length).read() as int) != 0 { length = length + 1 }
        let copy: Bytes = Bytes.from_raw(view, length)
        return copy.to_string()
    }
}

/// One connection. Move-only: it owns the libpq handle and finishes it.
pub partial unique class Connection implements Send {
    handle: RawPtr<sys.PGconn> = RawPtr.null()
    live: bool = false
    wait_ms: int = 30000
    // Prepared statements are per-connection, so the cache belongs here and
    // never to the pool. An int map, so there is no move-only map value.
    plans: Map<string, int> = {}
    plan_names: List<string> = []
    notices: List<Notification> = []
    in_transaction: bool = false

    fn init(handle: RawPtr<sys.PGconn>, wait_ms: int) {
        self.handle = handle
        self.live = true
        self.wait_ms = wait_ms
    }

    fn deinit() {
        // The backstop. `close()` exists for a caller who wants the error.
        if self.live {
            unsafe { sys.pqfinish(self.handle) }
            self.live = false
            self.handle = RawPtr.null()
        }
    }

    /// Connects, non-blocking from the first byte, parking the fiber on every
    /// wait that libpq asks for.
    pub static fn open(config: Config) -> Result<Connection, dbcore.DbError> {
        let text: Bytes = c_text(config.conninfo())
        var raw: RawPtr<sys.PGconn> = RawPtr.null()
        unsafe { raw = sys.pqconnectstart(as_char_ptr(text.as_ptr())) }
        if raw.is_null() {
            return err(new dbcore.DbError(dbcore.KIND_OUT_OF_MEMORY,
                "libpq could not allocate a connection"))
        }
        var state: int = 0
        unsafe { state = sys.pqstatus(raw) as int }
        if state == CONNECTION_BAD {
            let why: string = handle_message(raw)
            unsafe { sys.pqfinish(raw) }
            return err(new dbcore.DbError(dbcore.KIND_CONNECT,
                "cannot reach postgres at {config.address()}: {why}"))
        }
        let conn: Connection = new Connection(raw, config.connect_timeout_ms)
        conn.drive_connect(config)?
        var nonblocking: int = 0
        unsafe { nonblocking = sys.pqsetnonblocking(conn.handle, 1) as int }
        if nonblocking != 0 {
            return err(new dbcore.DbError(dbcore.KIND_PROTOCOL,
                "libpq refused non-blocking mode"))
        }
        conn.wait_ms = 0
        if config.statement_timeout_ms > 0 { conn.wait_ms = config.statement_timeout_ms }
        return ok(move conn)
    }

    // libpq's own documented non-blocking connect loop: before the first
    // poll the state is treated as WRITING.
    fn drive_connect(config: Config) -> Result<bool, dbcore.DbError> {
        var phase: int = POLLING_WRITING
        for {
            var fd: int = 0
            unsafe { fd = sys.pqsocket(self.handle) as int }
            if phase == POLLING_OK { return ok(true) }
            if phase == POLLING_FAILED {
                return err(new dbcore.DbError(dbcore.KIND_CONNECT,
                    "cannot reach postgres at {config.address()}: {self.message()}"))
            }
            if fd < 0 {
                return err(new dbcore.DbError(dbcore.KIND_CONNECT,
                    "libpq has no socket: {self.message()}"))
            }
            self.park(fd, phase == POLLING_WRITING, config.connect_timeout_ms)?
            unsafe { phase = sys.pqconnectpoll(self.handle) as int }
        }
        return err(new dbcore.DbError(dbcore.KIND_PROTOCOL, "unreachable"))
    }

    fn park(fd: int, write: bool, timeout_ms: int) -> Result<bool, dbcore.DbError> {
        var bound: int = timeout_ms
        if bound <= 0 { bound = -1 }
        match wait.wait_io(fd, write, bound) {
            ok(answer) => {
                match answer {
                    ready => { return ok(true) }
                    timed_out => {
                        return err(new dbcore.DbError(dbcore.KIND_TIMEOUT,
                            "postgres did not answer within {timeout_ms} ms"))
                    }
                }
            }
            err(why) => { return err(dbcore.from_error(why, dbcore.KIND_CLOSED)) }
        }
    }

    pub fn is_live() -> bool { return self.live }
    pub fn socket() -> int {
        var fd: int = 0
        unsafe { fd = sys.pqsocket(self.handle) as int }
        return fd
    }

    pub fn message() -> string { return handle_message(self.handle) }

    pub fn server_version() -> int {
        var version: int = 0
        unsafe { version = sys.pqserverversion(self.handle) as int }
        return version
    }

    pub fn backend_pid() -> int {
        var pid: int = 0
        unsafe { pid = sys.pqbackendpid(self.handle) as int }
        return pid
    }

    pub fn status() -> int {
        var state: int = 0
        unsafe { state = sys.pqstatus(self.handle) as int }
        return state
    }

    /// The default deadline for a statement, in milliseconds. 0 waits as long
    /// as the server does.
    pub fn set_wait(ms: int) { self.wait_ms = ms }

    pub fn close() -> Result<bool, dbcore.DbError> {
        if !self.live { return ok(false) }
        self.live = false
        unsafe { sys.pqfinish(self.handle) }
        self.handle = RawPtr.null()
        return ok(true)
    }
}

fn handle_message(handle: RawPtr<sys.PGconn>) -> string {
    if handle.is_null() { return "" }
    var text: string = ""
    unsafe { text = read_c_text(sys.pqerrormessage(handle)) }
    return text.trim()
}

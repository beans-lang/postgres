// LISTEN / NOTIFY.
//
// Two language facts shape this: a `Brew<T>` cannot be a field, so a
// connection cannot own its reader fiber, and one worker cannot park two
// fibers on one descriptor, so there is no reader-plus-writer pair. One fiber
// owns the connection; the caller brews it.
package postgres

import github.com/beans-lang/dbcore
import github.com/beans-lang/dbcore/wait
import postgres.sys

/// One `NOTIFY`, as it came off the wire.
pub class Notification {
    channel: string
    payload: string
    pid: int

    pub fn init(channel: string, payload: string, pid: int) {
        self.channel = channel
        self.payload = payload
        self.pid = pid
    }

    pub fn channel_name() -> string { return self.channel }
    pub fn body() -> string { return self.payload }
    pub fn sender_pid() -> int { return self.pid }

    pub fn to_string() -> string {
        return "{self.channel} {self.payload}"
    }
}

partial class Connection {
    /// Starts listening on a channel. An identifier is quoted, because a
    /// channel name is not a string literal to the server.
    pub fn listen(channel: string) -> Result<bool, dbcore.DbError> {
        self.execute("LISTEN {quote_identifier(channel)}", [])?
        return ok(true)
    }

    pub fn unlisten(channel: string) -> Result<bool, dbcore.DbError> {
        self.execute("UNLISTEN {quote_identifier(channel)}", [])?
        return ok(true)
    }

    pub fn unlisten_all() -> Result<bool, dbcore.DbError> {
        self.execute("UNLISTEN *", [])?
        return ok(true)
    }

    /// Sends one. `pg_notify` takes the channel as a value, so nothing has to
    /// be quoted and a channel name from a variable is safe.
    pub fn notify(channel: string, payload: string) -> Result<bool, dbcore.DbError> {
        self.execute("select pg_notify($1, $2)",
                     [dbcore.Value.of_text(channel),
                      dbcore.Value.of_text(payload)])?
        return ok(true)
    }

    /// The next notification, or `none` when `timeout_ms` passes with none.
    ///
    /// A `NotificationResponse` can arrive at any time, including between
    /// DataRows, so every query drains them into the same queue this reads.
    pub fn next_notification(timeout_ms: int) -> Result<Option<Notification>, dbcore.DbError> {
        if self.notices.len() > 0 { return ok(some(self.take_notice())) }
        if !self.live {
            return err(new dbcore.DbError(dbcore.KIND_CLOSED,
                "this connection is closed"))
        }
        let fd: int = self.socket()
        if fd < 0 {
            return err(new dbcore.DbError(dbcore.KIND_CLOSED,
                "this connection has no socket"))
        }
        var waited: int = 0
        for {
            self.drain_notifications()
            if self.notices.len() > 0 { return ok(some(self.take_notice())) }
            // A tick rather than the whole deadline: a caller that wants to
            // subscribe to one more channel gets its turn within one tick.
            var slice: int = 250
            if timeout_ms > 0 && timeout_ms - waited < slice {
                slice = timeout_ms - waited
            }
            if slice <= 0 { return ok(none) }
            match wait.wait_io(fd, false, slice) {
                ok(answer) => {
                    match answer {
                        ready => {
                            var consumed: int = 0
                            unsafe { consumed = sys.pqconsumeinput(self.handle) as int }
                            if consumed != 1 {
                                self.live = false
                                return err(new dbcore.DbError(dbcore.KIND_CLOSED,
                                    "the server closed the connection: {self.message()}"))
                            }
                        }
                        timed_out => {}
                    }
                }
                err(why) => { return err(dbcore.from_error(why, dbcore.KIND_CLOSED)) }
            }
            if timeout_ms > 0 {
                waited = waited + slice
                if waited >= timeout_ms {
                    self.drain_notifications()
                    if self.notices.len() > 0 { return ok(some(self.take_notice())) }
                    return ok(none)
                }
            }
        }
        return ok(none)
    }

    /// Notifications libpq has already parsed, taken all at once.
    pub fn take_notifications() -> List<Notification> {
        self.drain_notifications()
        var out: List<Notification> = []
        for item: Notification in self.notices { out.push(item) }
        self.notices.clear()
        return move out
    }

    fn take_notice() -> Notification {
        let first: Notification = self.notices[0]
        self.notices.remove(0)
        return first
    }

    // PQnotifies hands over memory libpq allocated; every field is copied out
    // and the block freed before the next call.
    fn drain_notifications() {
        for {
            var raw: RawPtr<sys.PGnotify> = RawPtr.null()
            unsafe { raw = sys.pqnotifies(self.handle) }
            if raw.is_null() { return }
            unsafe {
                let note: sys.PGnotify = raw.read()
                self.notices.push(
                    new Notification(read_c_text(note.relname),
                                     read_c_text(note.extra),
                                     note.be_pid as int))
                let block: RawPtr<u8> = RawPtr.from_address(raw.address())
                sys.pqfreemem(block)
            }
        }
    }
}

/// Wraps an identifier in double quotes, doubling any it contains — the rule
/// postgres itself uses for `quote_ident`.
pub fn quote_identifier(name: string) -> string {
    var out: string = "\""
    for index: int in 0..name.len() {
        let piece: string = name.slice(index, index + 1)
        if piece == "\"" { out = "{out}\"" }
        out = "{out}{piece}"
    }
    return "{out}\""
}

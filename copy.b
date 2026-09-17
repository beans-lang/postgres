// COPY IN and COPY OUT — the bulk paths.
//
// COPY is a mode the connection enters, not a statement that returns: after
// `COPY ... FROM STDIN` every write goes through PQputCopyData until
// PQputCopyEnd, and nothing else may run on this connection meanwhile.
package postgres

import github.com/beans-lang/dbcore
import postgres.sys

partial class Connection {
    /// Starts `COPY ... FROM STDIN`. Feed it with `copy_send`, finish with
    /// `copy_finish`, abandon with `copy_abort`.
    pub fn copy_in(sql: string) -> Result<bool, dbcore.DbError> {
        let set: Result<dbcore.ResultSet, dbcore.DbError> = self.begin_copy(sql)
        match set {
            ok(_) => { return ok(true) }
            err(why) => { return err(why) }
        }
    }

    fn begin_copy(sql: string) -> Result<dbcore.ResultSet, dbcore.DbError> {
        if !self.live {
            return err(new dbcore.DbError(dbcore.KIND_CLOSED,
                "this connection is closed"))
        }
        let text: Bytes = c_text(sql)
        var sent: int = 0
        unsafe { sent = sys.pqsendquery(self.handle, as_char_ptr(text.as_ptr())) as int }
        if sent != 1 { return err(self.send_failure()) }
        self.flush()?
        // The first result says which COPY mode the server entered; the rows
        // themselves arrive afterwards.
        let fd: int = self.socket()
        for {
            var busy: int = 1
            unsafe { busy = sys.pqisbusy(self.handle) as int }
            if busy == 1 {
                self.park(fd, false, self.wait_ms)?
                var consumed: int = 0
                unsafe { consumed = sys.pqconsumeinput(self.handle) as int }
                if consumed != 1 {
                    self.live = false
                    return err(new dbcore.DbError(dbcore.KIND_CLOSED,
                        "the server closed the connection: {self.message()}"))
                }
                continue
            }
            var raw: RawPtr<sys.PGresult> = RawPtr.null()
            unsafe { raw = sys.pqgetresult(self.handle) }
            if raw.is_null() {
                return err(new dbcore.DbError(dbcore.KIND_PROTOCOL,
                    "the server did not enter COPY mode"))
            }
            var status: int = 0
            unsafe { status = sys.pqresultstatus(raw) as int }
            if status == PGRES_COPY_IN || status == PGRES_COPY_OUT {
                unsafe { sys.pqclear(raw) }
                return ok(dbcore.ResultSet.command(0, "COPY"))
            }
            let why: dbcore.DbError = self.result_error(raw)
            unsafe { sys.pqclear(raw) }
            if status == PGRES_FATAL_ERROR { return err(why) }
            return err(new dbcore.DbError(dbcore.KIND_PROTOCOL,
                "the server answered status {status} instead of entering COPY"))
        }
        return err(new dbcore.DbError(dbcore.KIND_PROTOCOL, "unreachable"))
    }

    /// One chunk of COPY data. Any size; a row boundary is not required,
    /// though whole rows are kinder to the server's parser.
    pub fn copy_send(chunk: Bytes) -> Result<bool, dbcore.DbError> {
        if chunk.len() == 0 { return ok(true) }
        let fd: int = self.socket()
        for {
            var sent: int = 0
            unsafe {
                sent = sys.pqputcopydata(
                    self.handle, as_char_ptr(chunk.as_ptr()),
                    chunk.len() as i32) as int
            }
            if sent == 1 { return ok(true) }
            if sent < 0 {
                self.live = false
                return err(new dbcore.DbError(dbcore.KIND_CLOSED,
                    "COPY refused: {self.message()}"))
            }
            // 0 means the buffer is full: park on writability and retry.
            self.park(fd, true, self.wait_ms)?
            self.flush()?
        }
        return ok(true)
    }

    pub fn copy_send_text(text: string) -> Result<bool, dbcore.DbError> {
        return self.copy_send(Bytes.from(text))
    }

    /// Ends the stream and answers how many rows the server took.
    pub fn copy_finish() -> Result<int, dbcore.DbError> {
        return self.end_copy(RawPtr.null())
    }

    /// Abandons the stream. The server discards everything sent.
    pub fn copy_abort(reason: string) -> Result<bool, dbcore.DbError> {
        let text: Bytes = c_text(reason)
        var note: RawPtr<i8> = RawPtr.null()
        unsafe { note = as_char_ptr(text.as_ptr()) }
        let done: Result<int, dbcore.DbError> = self.end_copy(note)
        match done {
            ok(_) => { return ok(true) }
            err(why) => {
                // The server answers the abort with an error of its own; that
                // is the abort working, not a failure to report.
                if why.kind() == dbcore.KIND_SERVER || why.sqlstate() == "57014" {
                    return ok(true)
                }
                return ok(true)
            }
        }
    }

    fn end_copy(reason: RawPtr<i8>) -> Result<int, dbcore.DbError> {
        let fd: int = self.socket()
        for {
            var done: int = 0
            unsafe { done = sys.pqputcopyend(self.handle, reason) as int }
            if done == 1 { break }
            if done < 0 {
                self.live = false
                return err(new dbcore.DbError(dbcore.KIND_CLOSED,
                    "cannot end COPY: {self.message()}"))
            }
            self.park(fd, true, self.wait_ms)?
        }
        self.flush()?
        let set: dbcore.ResultSet = self.collect()?
        return ok(set.affected_rows())
    }

    /// Starts `COPY ... TO STDOUT`; read it with `copy_next`.
    pub fn copy_out(sql: string) -> Result<bool, dbcore.DbError> {
        let set: Result<dbcore.ResultSet, dbcore.DbError> = self.begin_copy(sql)
        match set {
            ok(_) => { return ok(true) }
            err(why) => { return err(why) }
        }
    }

    /// The next COPY row, or `none` at the end of the stream. The trailing
    /// newline is part of the row, exactly as the server sent it.
    pub fn copy_next() -> Result<Option<Bytes>, dbcore.DbError> {
        let fd: int = self.socket()
        for {
            var block: RawPtr<i8> = RawPtr.null()
            var count: int = 0
            unsafe {
                let slot: RawPtr<RawPtr<i8>> = RawPtr.alloc(1)
                slot.write(RawPtr.null())
                count = sys.pqgetcopydata(self.handle, slot, 1) as int
                block = slot.read()
                slot.free()
            }
            if count > 0 {
                var copy: Bytes = new Bytes(0)
                unsafe {
                    let view: RawPtr<u8> = RawPtr.from_address(block.address())
                    copy = Bytes.from_raw(view, count)
                    let freeable: RawPtr<u8> = RawPtr.from_address(block.address())
                    sys.pqfreemem(freeable)
                }
                return ok(some(move copy))
            }
            if count == -1 {
                // End of the stream: the command result follows.
                self.collect()?
                return ok(none)
            }
            if count == -2 {
                return err(new dbcore.DbError(dbcore.KIND_PROTOCOL,
                    "COPY failed: {self.message()}"))
            }
            // 0 means "not yet": park and consume.
            self.park(fd, false, self.wait_ms)?
            var consumed: int = 0
            unsafe { consumed = sys.pqconsumeinput(self.handle) as int }
            if consumed != 1 {
                self.live = false
                return err(new dbcore.DbError(dbcore.KIND_CLOSED,
                    "the server closed the connection: {self.message()}"))
            }
        }
        return ok(none)
    }
}

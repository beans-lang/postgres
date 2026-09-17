// Running statements: send, flush, park, consume, collect.
//
// This is the drive loop the whole package exists for. `PQsendQueryParams`
// buffers; `PQflush` drains, parking on writability when the kernel is full;
// then the fiber parks on readability until `PQisBusy` says a whole result
// has arrived.
package postgres

import github.com/beans-lang/dbcore
import postgres.sys

partial class Connection {

    /// A parameterised query. Parameters are `$1`, `$2`, ... — never string
    /// interpolation, which is how an injection gets written.
    pub fn query(sql: string,
                 params: List<dbcore.Value>) -> Result<dbcore.ResultSet, dbcore.DbError> {
        self.send_query(sql, params)?
        return self.collect()
    }

    /// The same, for a statement with no rows; answers the affected count.
    pub fn execute(sql: string,
                   params: List<dbcore.Value>) -> Result<int, dbcore.DbError> {
        let set: dbcore.ResultSet = self.query(sql, params)?
        return ok(set.affected_rows())
    }

    /// One row, or `none`. Adds no LIMIT — say so in the SQL if you mean it.
    pub fn query_one(sql: string,
                     params: List<dbcore.Value>) -> Result<Option<dbcore.Row>, dbcore.DbError> {
        let set: dbcore.ResultSet = self.query(sql, params)?
        return ok(set.first())
    }

    /// A single scalar: the first column of the first row, or NULL.
    pub fn query_value(sql: string,
                       params: List<dbcore.Value>) -> Result<dbcore.Value, dbcore.DbError> {
        let set: dbcore.ResultSet = self.query(sql, params)?
        return ok(set.scalar())
    }

    /// Several statements in one string, no parameters — the shape a schema
    /// migration wants. Answers the last result.
    pub fn execute_script(sql: string) -> Result<int, dbcore.DbError> {
        if !self.live {
            return err(new dbcore.DbError(dbcore.KIND_CLOSED,
                "this connection is closed"))
        }
        let text: Bytes = c_text(sql)
        var sent: int = 0
        unsafe { sent = sys.pqsendquery(self.handle, as_char_ptr(text.as_ptr())) as int }
        if sent != 1 { return err(self.send_failure()) }
        self.flush()?
        let set: dbcore.ResultSet = self.collect()?
        return ok(set.affected_rows())
    }

    fn send_query(sql: string,
                  params: List<dbcore.Value>) -> Result<bool, dbcore.DbError> {
        if !self.live {
            return err(new dbcore.DbError(dbcore.KIND_CLOSED,
                "this connection is closed"))
        }
        let text: Bytes = c_text(sql)
        var sent: int = 0
        if params.len() == 0 {
            unsafe {
                sent = sys.pqsendqueryparams(
                    self.handle, as_char_ptr(text.as_ptr()), 0,
                    RawPtr.null(), RawPtr.null(), RawPtr.null(),
                    RawPtr.null(), 0) as int
            }
        } else {
            let bound: BoundParams = bind_params(params)
            unsafe {
                sent = sys.pqsendqueryparams(
                    self.handle, as_char_ptr(text.as_ptr()), params.len() as i32,
                    RawPtr.null(), bound.values, bound.lengths, bound.formats,
                    0) as int
            }
            bound.free()
        }
        if sent != 1 { return err(self.send_failure()) }
        self.flush()?
        return ok(true)
    }

    fn send_failure() -> dbcore.DbError {
        let why: string = self.message()
        if !self.live || self.status() == CONNECTION_BAD {
            self.live = self.status() != CONNECTION_BAD
            return new dbcore.DbError(dbcore.KIND_CLOSED,
                "the connection is gone: {why}")
        }
        return new dbcore.DbError(dbcore.KIND_PROTOCOL, "cannot send: {why}")
    }

    // A send only buffers. Drain it, parking on writability while the
    // kernel's buffer is full.
    fn flush() -> Result<bool, dbcore.DbError> {
        let fd: int = self.socket()
        for {
            var pending: int = 0
            unsafe { pending = sys.pqflush(self.handle) as int }
            if pending == 0 { return ok(true) }
            if pending < 0 {
                self.live = false
                return err(new dbcore.DbError(dbcore.KIND_CLOSED,
                    "cannot write to the server: {self.message()}"))
            }
            self.park(fd, true, self.wait_ms)?
        }
        return ok(true)
    }

    /// Reads every result of the statement in flight and answers the last one
    /// that carried rows, or the last command's tag.
    pub fn collect() -> Result<dbcore.ResultSet, dbcore.DbError> {
        let fd: int = self.socket()
        var answer: dbcore.ResultSet = dbcore.ResultSet.command(0, "")
        var have: bool = false
        var failure: Option<dbcore.DbError> = none
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
            if raw.is_null() { break }
            var status: int = 0
            unsafe { status = sys.pqresultstatus(raw) as int }
            if status == PGRES_FATAL_ERROR || status == PGRES_BAD_RESPONSE {
                match failure {
                    some(_) => {}
                    none => { failure = some(self.result_error(raw)) }
                }
            } else if status == PGRES_TUPLES_OK || status == PGRES_SINGLE_TUPLE {
                answer = read_result(raw)
                have = true
            } else if status == PGRES_COMMAND_OK {
                if !have { answer = command_result(raw) }
            }
            unsafe { sys.pqclear(raw) }
        }
        self.drain_notifications()
        match failure {
            some(why) => { return err(why) }
            none => { return ok(answer) }
        }
    }

    fn result_error(raw: RawPtr<sys.PGresult>) -> dbcore.DbError {
        let state: string = result_field(raw, DIAG_SQLSTATE)
        var text: string = result_field(raw, DIAG_MESSAGE_PRIMARY)
        if text == "" {
            unsafe { text = read_c_text(sys.pqresulterrormessage(raw)).trim() }
        }
        let error: dbcore.DbError = dbcore.DbError.full(
            dbcore.kind_from_sqlstate(state), text, state, 0,
            result_field(raw, DIAG_CONSTRAINT_NAME))
        return error.with_detail(result_field(raw, DIAG_MESSAGE_DETAIL),
                                 result_field(raw, DIAG_MESSAGE_HINT))
    }

    /// Asks the server to stop the statement in flight, from a second
    /// connection — the fiber that wants to cancel cannot be the one parked
    /// on this socket.
    pub fn cancel() -> Result<bool, dbcore.DbError> {
        var handle: RawPtr<sys.PGcancel> = RawPtr.null()
        unsafe { handle = sys.pqgetcancel(self.handle) }
        if handle.is_null() {
            return err(new dbcore.DbError(dbcore.KIND_CLOSED,
                "there is nothing to cancel"))
        }
        var buffer: Bytes = new Bytes(256)
        var ok_flag: int = 0
        unsafe {
            ok_flag = sys.pqcancel(handle, as_char_ptr(buffer.as_ptr()), 256) as i32 as int
            sys.pqfreecancel(handle)
        }
        if ok_flag != 1 {
            return err(new dbcore.DbError(dbcore.KIND_PROTOCOL,
                "cancel refused: {buffer.to_string_until_nul()}"))
        }
        return ok(true)
    }
}

fn result_field(raw: RawPtr<sys.PGresult>, code: int) -> string {
    var text: string = ""
    unsafe { text = read_c_text(sys.pqresulterrorfield(raw, code as i32)) }
    return text
}

fn command_result(raw: RawPtr<sys.PGresult>) -> dbcore.ResultSet {
    var affected: int = 0
    var tag: string = ""
    unsafe {
        affected = read_c_text(sys.pqcmdtuples(raw)).to_int().or(0)
        tag = read_c_text(sys.pqcmdstatus(raw))
    }
    return dbcore.ResultSet.command(affected, tag)
}

fn read_result(raw: RawPtr<sys.PGresult>) -> dbcore.ResultSet {
    var width: int = 0
    var rows: int = 0
    unsafe {
        width = sys.pqnfields(raw) as int
        rows = sys.pqntuples(raw) as int
    }
    var heads: List<dbcore.Column> = []
    var oids: List<int> = []
    for column: int in 0..width {
        var name: string = ""
        var oid: int = 0
        unsafe {
            name = read_c_text(sys.pqfname(raw, column as i32))
            oid = sys.pqftype(raw, column as i32) as int
        }
        oids.push(oid)
        heads.push(dbcore.Column.typed(name, oid, type_name(oid)))
    }
    let set: dbcore.ResultSet = new dbcore.ResultSet(move heads)
    for row: int in 0..rows {
        for column: int in 0..width {
            var is_null: int = 0
            unsafe { is_null = sys.pqgetisnull(raw, row as i32, column as i32) as int }
            if is_null == 1 {
                set.push_cell(dbcore.Value.null())
                continue
            }
            var text: string = ""
            unsafe { text = read_c_text(sys.pqgetvalue(raw, row as i32, column as i32)) }
            set.push_cell(decode_text(oids[column], text))
        }
    }
    var affected: int = 0
    var tag: string = ""
    unsafe {
        affected = read_c_text(sys.pqcmdtuples(raw)).to_int().or(0)
        tag = read_c_text(sys.pqcmdstatus(raw))
    }
    set.set_affected(affected)
    set.set_tag(tag)
    return set
}

// libpq takes three parallel C arrays, allocated for the call and freed right
// after it, so nothing outlives the statement.
class BoundParams {
    values: RawPtr<RawPtr<i8>>
    lengths: RawPtr<i32>
    formats: RawPtr<i32>
    blocks: List<Bytes> = []

    fn init(count: int) {
        unsafe {
            self.values = RawPtr.alloc(count)
            self.lengths = RawPtr.alloc(count)
            self.formats = RawPtr.alloc(count)
        }
    }

    fn free() {
        unsafe {
            self.values.free()
            self.lengths.free()
            self.formats.free()
        }
    }
}

// Text format for every parameter, including bytea, which postgres accepts as
// `\x` hex on input. One format means one encoder rather than one per type.
fn bind_params(params: List<dbcore.Value>) -> BoundParams {
    let bound: BoundParams = new BoundParams(params.len())
    for index: int in 0..params.len() {
        let value: dbcore.Value = params[index]
        if value.is_null() {
            unsafe {
                bound.values.offset(index).write(RawPtr.null())
                bound.lengths.offset(index).write(0)
                bound.formats.offset(index).write(0)
            }
            continue
        }
        let text: string = encode_param(value)
        var block: Bytes = c_text(text)
        unsafe {
            bound.values.offset(index).write(as_char_ptr(block.as_ptr()))
            bound.lengths.offset(index).write((block.len() - 1) as i32)
            bound.formats.offset(index).write(0)
        }
        bound.blocks.push(move block)
    }
    return bound
}

/// A `Value` in the text form postgres parses on input.
pub fn encode_param(value: dbcore.Value) -> string {
    match value.kind() {
        null_value => { return "" }
        bool_value => { if value.as_bool() { return "t" } return "f" }
        int_value => { return "{value.as_int()}" }
        float_value => { return "{value.as_float()}" }
        decimal_value => { return value.as_text() }
        text_value => { return value.as_text() }
        json_value => { return value.as_text() }
        uuid_value => { return value.as_text() }
        bytes_value => { return "\\x{dbcore.hex_of(value.as_bytes())}" }
        timestamp_value => { return "{value.as_int()}" }
        array_value => { return encode_array(value) }
    }
}

fn encode_array(value: dbcore.Value) -> string {
    var out: string = "\{"
    for index: int in 0..value.array_count() {
        if index != 0 { out = "{out}," }
        let item: dbcore.Value = value.array_at(index)
        if item.is_null() { out = "{out}NULL"; continue }
        out = "{out}{quote_array_element(encode_param(item))}"
    }
    return "{out}\}"
}

// Always quoted: an element holding a comma, a brace, a quote or the four
// letters NULL is otherwise read as structure.
fn quote_array_element(text: string) -> string {
    var out: string = "\""
    for index: int in 0..text.len() {
        let piece: string = text.slice(index, index + 1)
        if piece == "\"" || piece == "\\" { out = "{out}\\" }
        out = "{out}{piece}"
    }
    return "{out}\""
}

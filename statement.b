// Prepared statements.
//
// Names are per-connection, so the cache belongs to the Connection and never
// to the Pool. It is a `Map<string, int>` into a name list rather than a map
// of statements, because a move-only map value allows one live reader.
package postgres

import github.com/beans-lang/dbcore
import postgres.sys

pub const STATEMENT_CACHE_MAX: int = 128

partial class Connection {
    /// Prepares `sql` and answers a handle into this connection's cache.
    /// Preparing the same text twice answers the same handle.
    pub fn prepare(sql: string) -> Result<int, dbcore.DbError> {
        if self.plans.contains_key(sql) { return ok(self.plans[sql]) }
        if !self.live {
            return err(new dbcore.DbError(dbcore.KIND_CLOSED,
                "this connection is closed"))
        }
        if self.plan_names.len() >= STATEMENT_CACHE_MAX {
            self.evict_oldest()?
        }
        let name: string = "beans_pg_{self.plan_names.len()}_{self.backend_pid()}"
        let name_text: Bytes = c_text(name)
        let sql_text: Bytes = c_text(sql)
        var sent: int = 0
        unsafe {
            sent = sys.pqsendprepare(
                self.handle, as_char_ptr(name_text.as_ptr()),
                as_char_ptr(sql_text.as_ptr()), 0, RawPtr.null()) as int
        }
        if sent != 1 { return err(self.send_failure()) }
        self.flush()?
        self.collect()?
        let handle: int = self.plan_names.len()
        self.plan_names.push(name)
        self.plans[sql] = handle
        return ok(handle)
    }

    /// Runs a statement prepared earlier.
    pub fn query_prepared(handle: int,
                          params: List<dbcore.Value>) -> Result<dbcore.ResultSet, dbcore.DbError> {
        if handle < 0 || handle >= self.plan_names.len() {
            return err(new dbcore.DbError(dbcore.KIND_DECODE,
                "statement handle {handle} is not from this connection"))
        }
        if !self.live {
            return err(new dbcore.DbError(dbcore.KIND_CLOSED,
                "this connection is closed"))
        }
        let name_text: Bytes = c_text(self.plan_names[handle])
        var sent: int = 0
        if params.len() == 0 {
            unsafe {
                sent = sys.pqsendqueryprepared(
                    self.handle, as_char_ptr(name_text.as_ptr()), 0,
                    RawPtr.null(), RawPtr.null(), RawPtr.null(), 0) as int
            }
        } else {
            let bound: BoundParams = bind_params(params)
            unsafe {
                sent = sys.pqsendqueryprepared(
                    self.handle, as_char_ptr(name_text.as_ptr()),
                    params.len() as i32, bound.values, bound.lengths,
                    bound.formats, 0) as int
            }
            bound.free()
        }
        if sent != 1 { return err(self.send_failure()) }
        self.flush()?
        return self.collect()
    }

    pub fn execute_prepared(handle: int,
                            params: List<dbcore.Value>) -> Result<int, dbcore.DbError> {
        let set: dbcore.ResultSet = self.query_prepared(handle, params)?
        return ok(set.affected_rows())
    }

    pub fn prepared_count() -> int { return self.plan_names.len() }

    // The cache is capped so a program building SQL in a loop cannot make the
    // server hold an unbounded number of plans.
    fn evict_oldest() -> Result<bool, dbcore.DbError> {
        if self.plan_names.len() == 0 { return ok(false) }
        let name: string = self.plan_names[0]
        let text: Bytes = c_text("DEALLOCATE {quote_identifier(name)}")
        var sent: int = 0
        unsafe { sent = sys.pqsendquery(self.handle, as_char_ptr(text.as_ptr())) as int }
        if sent == 1 {
            self.flush()?
            let ignored: Result<dbcore.ResultSet, dbcore.DbError> = self.collect()
        }
        // Handles are indexes, so the list keeps its shape: the evicted slot
        // is blanked rather than removed, and its SQL leaves the map.
        var evicted: string = ""
        for key: string in self.plans.keys() {
            if self.plans[key] == 0 { evicted = key }
        }
        if evicted != "" { self.plans.remove(evicted) }
        self.plan_names[0] = ""
        return ok(true)
    }
}

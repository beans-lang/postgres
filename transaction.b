// Transactions.
//
// There is no RAII rollback, and that is the design. `deinit` may not park
// and ROLLBACK is a round trip, so a transaction left open marks its
// connection dirty and the pool cleans up on a call that may park.
package postgres

import github.com/beans-lang/dbcore

partial class Connection {
    /// BEGIN at the given isolation level.
    pub fn begin(level: Isolation) -> Result<bool, dbcore.DbError> {
        self.execute("BEGIN ISOLATION LEVEL {isolation_sql(level)}", [])?
        self.in_transaction = true
        return ok(true)
    }

    pub fn begin_read_committed() -> Result<bool, dbcore.DbError> {
        return self.begin(Isolation.read_committed)
    }

    pub fn commit() -> Result<bool, dbcore.DbError> {
        self.execute("COMMIT", [])?
        self.in_transaction = false
        return ok(true)
    }

    pub fn rollback() -> Result<bool, dbcore.DbError> {
        let done: Result<int, dbcore.DbError> = self.execute("ROLLBACK", [])
        self.in_transaction = false
        match done {
            ok(_) => { return ok(true) }
            err(why) => { return err(why) }
        }
    }

    pub fn savepoint(name: string) -> Result<bool, dbcore.DbError> {
        self.execute("SAVEPOINT {quote_identifier(name)}", [])?
        return ok(true)
    }

    pub fn rollback_to(name: string) -> Result<bool, dbcore.DbError> {
        self.execute("ROLLBACK TO SAVEPOINT {quote_identifier(name)}", [])?
        return ok(true)
    }

    pub fn release_savepoint(name: string) -> Result<bool, dbcore.DbError> {
        self.execute("RELEASE SAVEPOINT {quote_identifier(name)}", [])?
        return ok(true)
    }

    /// True while a BEGIN this package issued has not been ended.
    pub fn is_in_transaction() -> bool { return self.in_transaction }

    /// Runs `body` between BEGIN and COMMIT, rolling back on any failure —
    /// including a `?` that left early.
    ///
    /// The rollback runs here, in an ordinary call that may park, which is
    /// exactly why it is a closure and not a `deinit`.
    pub fn transaction<R>(level: Isolation,
                          move body: fn() -> Result<R, dbcore.DbError>) -> Result<R, dbcore.DbError> {
        self.begin(level)?
        let answer: Result<R, dbcore.DbError> = body()
        match answer {
            ok(_) => {}
            err(why) => {
                let rolled: Result<bool, dbcore.DbError> = self.rollback()
                return err(why)
            }
        }
        self.commit()?
        return answer
    }
}

// A pool of postgres connections, and the DI-facing concrete type.
package postgres

import github.com/beans-lang/dbcore

pub class Pool {
    inner: dbcore.Pool<Connection>
    address: string = ""

    fn init(move inner: dbcore.Pool<Connection>, address: string) {
        self.inner = move inner
        self.address = address
    }

    /// Opens one connection now, so bad credentials fail here and not at the
    /// first query, and keeps at most `size`.
    pub static fn open(config: Config, size: int) -> Result<Pool, dbcore.DbError> {
        let seed: Connection = Connection.open(config)?
        let inner: dbcore.Pool<Connection> =
            dbcore.Pool.open<Connection>(
                new dbcore.PoolConfig(size), move seed,
                fn() -> Result<Connection, dbcore.DbError> {
                    return Connection.open(config)
                })?
        return ok(new Pool(move inner, config.address()))
    }

    /// Lends one connection to `body` and always takes it back — on the ok
    /// path, on an error, and on a body that failed.
    ///
    /// A transaction, a prepared statement or a COPY needs every step on one
    /// connection, which is exactly what this is for.
    pub fn with_connection<R>(
            move body: fn(Connection) -> Result<R, dbcore.DbError>
    ) -> Result<R, dbcore.DbError> {
        return self.inner.with_connection<R>(move body)
    }

    /// Refuses instead of waiting when every connection is out.
    pub fn try_with_connection<R>(
            move body: fn(Connection) -> Result<R, dbcore.DbError>
    ) -> Result<R, dbcore.DbError> {
        return self.inner.try_with_connection<R>(move body)
    }

    pub fn query(sql: string,
                 params: List<dbcore.Value>) -> Result<dbcore.ResultSet, dbcore.DbError> {
        return self.inner.with_connection<dbcore.ResultSet>(
            fn(conn: Connection) -> Result<dbcore.ResultSet, dbcore.DbError> {
                return conn.query(sql, params)
            })
    }

    pub fn execute(sql: string,
                   params: List<dbcore.Value>) -> Result<int, dbcore.DbError> {
        return self.inner.with_connection<int>(
            fn(conn: Connection) -> Result<int, dbcore.DbError> {
                return conn.execute(sql, params)
            })
    }

    pub fn query_value(sql: string,
                       params: List<dbcore.Value>) -> Result<dbcore.Value, dbcore.DbError> {
        return self.inner.with_connection<dbcore.Value>(
            fn(conn: Connection) -> Result<dbcore.Value, dbcore.DbError> {
                return conn.query_value(sql, params)
            })
    }

    pub fn ping() -> Result<bool, dbcore.DbError> {
        return self.inner.with_connection<bool>(
            fn(conn: Connection) -> Result<bool, dbcore.DbError> {
                conn.execute("select 1", [])?
                return ok(true)
            })
    }

    pub fn node_address() -> string { return self.address }
    pub fn stats() -> dbcore.PoolStats { return self.inner.stats() }
    pub fn close() -> Result<bool, dbcore.DbError> { return self.inner.close() }

    /// The name barista's `Disposable` calls.
    pub fn dispose() { self.inner.dispose() }
}

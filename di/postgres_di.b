// Registering a postgres pool with barista.
package postgres_di

import github.com/beans-lang/barista
import github.com/beans-lang/dbcore
import postgres

/// A pool the container owns and releases. `deinit` is the wrong place for a
/// socket, and a DI graph is where the cycles that skip `deinit` form.
pub class PgPool implements barista.Disposable {
    pool: postgres.Pool

    pub fn init(pool: postgres.Pool) { self.pool = pool }

    pub static fn open(config: postgres.Config,
                       size: int) -> Result<PgPool, dbcore.DbError> {
        return ok(new PgPool(postgres.Pool.open(config, size)?))
    }

    pub fn handle() -> postgres.Pool { return self.pool }

    pub fn query(sql: string,
                 params: List<dbcore.Value>) -> Result<dbcore.ResultSet, dbcore.DbError> {
        return self.pool.query(sql, params)
    }

    pub fn execute(sql: string,
                   params: List<dbcore.Value>) -> Result<int, dbcore.DbError> {
        return self.pool.execute(sql, params)
    }

    pub fn stats() -> dbcore.PoolStats { return self.pool.stats() }

    pub override fn dispose() { self.pool.dispose() }
}

/// Registers a `PgPool` singleton, released when the root provider closes.
pub fn add_postgres(services: barista.ServiceCollection, config: postgres.Config,
                    size: int) -> Result<bool> {
    return barista.add_singleton_factory<PgPool>(services,
        fn(provider: barista.ServiceProvider) -> Result<PgPool> {
            let opened: Result<PgPool, dbcore.DbError> = PgPool.open(config, size)
            match opened {
                ok(pool) => { return ok(pool) }
                err(why) => { return err(why.to_error()) }
            }
        })
}

// Pipeline mode: several statements in flight, one round trip.
package postgres

import github.com/beans-lang/dbcore
import postgres.sys

/// A queue of statements to send together.
pub class Pipeline {
    statements: List<string> = []
    bindings: List<List<dbcore.Value>> = []

    pub fn init() {}

    pub fn queue(sql: string, params: List<dbcore.Value>) -> Pipeline {
        var copy: List<dbcore.Value> = []
        for value: dbcore.Value in params { copy.push(value) }
        self.statements.push(sql)
        self.bindings.push(move copy)
        return self
    }

    pub fn len() -> int { return self.statements.len() }
    pub fn is_empty() -> bool { return self.statements.len() == 0 }
    pub fn clear() {
        self.statements.clear()
        self.bindings.clear()
    }
}

/// The answers of one pipeline run. Not a plain `List<ResultSet>`, because a
/// move-only list cannot come back out of a pool checkout.
pub class PipelineResults {
    sets: List<dbcore.ResultSet> = []

    pub fn init(move sets: List<dbcore.ResultSet>) { self.sets = move sets }

    pub fn len() -> int { return self.sets.len() }
    pub fn at(index: int) -> dbcore.ResultSet { return self.sets[index] }

    pub fn to_string() -> string {
        var out: string = ""
        for index: int in 0..self.sets.len() {
            if index != 0 { out = "{out}\n" }
            out = "{out}[{index}] {self.sets[index].to_string()}"
        }
        return out
    }
}

partial class Connection {
    /// Sends every queued statement in one round trip and reads every answer.
    ///
    /// The first failure ends the batch: postgres aborts a pipeline at the
    /// first error and skips to the sync, so a later statement's "result" is
    /// `PGRES_PIPELINE_ABORTED` and never an answer.
    pub fn run_pipeline(pipeline: Pipeline) -> Result<PipelineResults, dbcore.DbError> {
        if pipeline.is_empty() { return ok(new PipelineResults([])) }
        if !self.live {
            return err(new dbcore.DbError(dbcore.KIND_CLOSED,
                "this connection is closed"))
        }
        var entered: int = 0
        unsafe { entered = sys.pqenterpipelinemode(self.handle) as int }
        if entered != 1 {
            return err(new dbcore.DbError(dbcore.KIND_UNSUPPORTED,
                "this server does not do pipelining: {self.message()}"))
        }
        let outcome: Result<PipelineResults, dbcore.DbError> = self.drive_pipeline(pipeline)
        var left: int = 0
        unsafe { left = sys.pqexitpipelinemode(self.handle) as int }
        return outcome
    }

    fn drive_pipeline(pipeline: Pipeline) -> Result<PipelineResults, dbcore.DbError> {
        for index: int in 0..pipeline.len() {
            let text: Bytes = c_text(pipeline.statements[index])
            var params: List<dbcore.Value> = []
            for value: dbcore.Value in pipeline.bindings[index] {
                params.push(value)
            }
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
                        self.handle, as_char_ptr(text.as_ptr()),
                        params.len() as i32, RawPtr.null(), bound.values,
                        bound.lengths, bound.formats, 0) as int
                }
                bound.free()
            }
            if sent != 1 { return err(self.send_failure()) }
        }
        var synced: int = 0
        unsafe { synced = sys.pqpipelinesync(self.handle) as int }
        if synced != 1 { return err(self.send_failure()) }
        self.flush()?
        var sets: List<dbcore.ResultSet> = []
        var failure: Option<dbcore.DbError> = none
        for _: int in 0..pipeline.len() {
            let one: Result<dbcore.ResultSet, dbcore.DbError> = self.collect()
            match one {
                ok(set) => { sets.push(set) }
                err(why) => {
                    match failure {
                        some(_) => {}
                        none => { failure = some(why) }
                    }
                    sets.push(dbcore.ResultSet.command(0, "ABORTED"))
                }
            }
        }
        // The sync's own result closes the batch.
        let closing: Result<dbcore.ResultSet, dbcore.DbError> = self.collect()
        match failure {
            some(why) => { return err(why) }
            none => { return ok(new PipelineResults(move sets)) }
        }
    }
}

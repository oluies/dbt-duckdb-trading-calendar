// Runs the cpt change point extension in the browser through DuckDB-WASM.
// Loaded lazily: nothing is downloaded until the reader asks for it. The
// Scala.js app talks to this through the FxDuck facade (Live.scala).
//
// The version is pinned: an extension only loads in the DuckDB release it
// supports. cpt.duckdb_extension.wasm needs DuckDB 2.0; this release is the
// DuckDB-WASM build of v2.0.0. npm's "latest" tag is still DuckDB 1.5.4.
window.FxDuck = {
  async start(returns, extensionUrl) {
    const VERSION = '1.33.1-dev114.0';
    const duckdb = await import(`https://cdn.jsdelivr.net/npm/@duckdb/duckdb-wasm@${VERSION}/+esm`);
    const bundle = await duckdb.selectBundle(duckdb.getJsDelivrBundles());
    const workerUrl = URL.createObjectURL(
      new Blob([`importScripts("${bundle.mainWorker}");`], { type: 'text/javascript' })
    );
    const db = new duckdb.AsyncDuckDB(new duckdb.VoidLogger(), new Worker(workerUrl));
    await db.instantiate(bundle.mainModule, bundle.pthreadWorker);
    URL.revokeObjectURL(workerUrl);
    await db.open({ allowUnsignedExtensions: true });
    const conn = await db.connect();
    await conn.query(`LOAD '${new URL(extensionUrl, location.href).href}'`);
    await conn.query(`CREATE TEMP TABLE series AS SELECT [${returns.join(',')}]::DOUBLE[] AS xs`);

    return {
      // penalty is 'mbic', 'bic', 'aic' (with the quotes) or a number.
      async run(penalty, minDays) {
        if (!/^('mbic'|'bic'|'aic'|\d+(\.\d+)?)$/.test(penalty)) throw new Error(`bad penalty: ${penalty}`);
        if (!Number.isInteger(minDays) || minDays < 2) throw new Error(`bad minimum length: ${minDays}`);
        const result = await conn.query(
          `SELECT unnest(cpt_segment_stats(xs, cpt_pelt(xs, 'normal', ${penalty}, ${minDays}))) AS seg FROM series`
        );
        return result.toArray().map(row => {
          const s = row.seg.toJSON();
          return { start: Number(s.start), end: Number(s.end), n: Number(s.n), mean: s.mean, variance: s.var };
        });
      },
    };
  },
};

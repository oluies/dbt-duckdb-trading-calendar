# Assemble the deployable site in dist/: index.html, the linked Scala.js
# bundle, the data and the DuckDB-WASM bridge with the cpt extension.
# public/cpt.duckdb_extension.wasm is the wasm_eh artifact of the
# hugr-lab/duck-changepoint CI, built for DuckDB v2.0.0 at commit f017516.
# Refresh the data first with
#   uv run ../scripts/export_fx_regimes_json.py
.PHONY: dist serve clean

dist:
	./mill app.fullLinkJS
	rm -rf dist && mkdir -p dist
	cp index.html duckdb-bridge.js public/fx_regimes.json public/cpt.duckdb_extension.wasm dist/
	cp out/app/fullLinkJS.dest/main.js dist/

serve: dist
	python3 -m http.server -d dist 8099

clean:
	rm -rf dist out

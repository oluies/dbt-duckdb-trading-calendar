# Assemble the deployable site in dist/: index.html, the linked Scala.js
# bundle and the data. Refresh the data first with
#   uv run ../scripts/export_fx_regimes_json.py
.PHONY: dist serve clean

dist:
	./mill app.fullLinkJS
	rm -rf dist && mkdir -p dist
	cp index.html public/fx_regimes.json dist/
	cp out/app/fullLinkJS.dest/main.js dist/

serve: dist
	python3 -m http.server -d dist 8099

clean:
	rm -rf dist out

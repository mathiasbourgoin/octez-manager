.PHONY: build test clean coverage

OPAM_EXEC ?= opam exec --
DUNE = $(OPAM_EXEC) dune
BISECT = $(OPAM_EXEC) bisect-ppx-report

build:
	$(DUNE) build

test:
	$(DUNE) runtest

clean:
	$(DUNE) clean

coverage: clean
	@echo "[coverage] running instrumented test suite"
	@rm -rf _coverage && mkdir -p _coverage
	@BISECT_FILE=$(CURDIR)/_coverage/bisect $(DUNE) runtest --instrument-with bisect_ppx
	@COVERAGE_FILES=$$(find _coverage -name '*.coverage' -print); \
		$(BISECT) summary --per-file $$COVERAGE_FILES | tee _coverage/summary.txt; \
		$(BISECT) html -o _coverage/html $$COVERAGE_FILES
	@echo "[coverage] summary saved to _coverage/summary.txt"
	@echo "[coverage] html report available under _coverage/html/index.html"

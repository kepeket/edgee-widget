SHELL := /bin/bash

.PHONY: build debug run demo test

build:
	./scripts/build-app.sh --release

debug:
	./scripts/build-app.sh --debug

run:
	./scripts/run.sh --release $(ARGS)

demo:
	./scripts/run.sh --release --demo --window

test:
	swift test

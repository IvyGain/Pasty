# Pasty — convenience targets for everyday development & release.
# All shell-out is funnelled through ./scripts/dev.sh so the Xcode/SDK
# environment is consistent regardless of how `xcode-select` is set.

.PHONY: help build run test demo package release dmg clean

help:
	@echo "Pasty Makefile targets:"
	@echo "  make build      — debug build via SwiftPM"
	@echo "  make run        — build + run in foreground"
	@echo "  make test       — run XCTest (requires Xcode license accepted)"
	@echo "  make demo       — automated smoke test"
	@echo "  make package    — debug .app + .dmg under dist/"
	@echo "  make release    — release .app + .dmg under dist/"
	@echo "  make dmg        — alias for make package"
	@echo "  make clean      — remove .build/ and dist/"

build:
	./scripts/dev.sh build

run:
	./scripts/dev.sh run Pasty

test:
	./scripts/dev.sh test

demo:
	./scripts/dev.sh demo

package:
	./scripts/package.sh debug

dmg: package

release:
	./scripts/package.sh release

clean:
	rm -rf .build dist

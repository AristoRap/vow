SHELL := /bin/sh


.PHONY: help setup test build release copy deploy clean

help:
	@echo "  make setup            install Crystal deps (shards)"
	@echo "  make test             specs"
	@echo "  make build            test + build CLI binary (bin/vow)"
	@echo "  make release          test + build CLI binary (--release)"
	@echo "  make copy             copy binary to /usr/local/bin (rm+cp, never cp -f)"
	@echo "  make deploy           release + copy  (the end-of-task command)"
	@echo "  make clean            remove build artifacts"

setup:
	shards install

# Fast unit specs. Mirrors the old split: integration (real subprocess) is
# separate so the common loop stays sub-second.
test:
	crystal spec

build:
	$(MAKE) test && shards build

release:
	$(MAKE) test && shards build --release

# macOS: NEVER `cp -f` over the live binary — adhoc signatures are inode-cached
# and the kernel SIGKILLs the running process (exit 137, EPIPE, no logs). rm
# then cp gives a fresh inode.
copy:
	rm -f /usr/local/bin/vow
	cp ./bin/vow /usr/local/bin/vow

deploy:
	$(MAKE) release && $(MAKE) copy

clean:
	rm -rf bin/vow bin/vow.dwarf

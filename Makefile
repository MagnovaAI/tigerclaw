.PHONY: build run test fmt fmt-check clean

build:
	zig build

run:
	zig build run

test:
	zig build test --summary all

fmt:
	zig fmt src/ tests/ build.zig

fmt-check:
	zig fmt --check src/ tests/ build.zig

clean:
	rm -rf zig-out .zig-cache

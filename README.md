# tigerclaw

An agent runtime written in Zig.

> Pre-alpha. Nothing works yet. This is the initial scaffold.

## Requirements

- [Zig `0.16.0`](https://ziglang.org/download/)

## Build

```sh
zig build          # compile
zig build run      # compile + run
zig build test     # run unit tests
```

## Layout

```
.
├── build.zig         # build script
├── build.zig.zon     # package manifest
└── src/
    └── main.zig      # entry point
```

## License

[MIT](LICENSE)

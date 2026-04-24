# libpcre.zig

Use via the zig package manager:

```sh
$ zig fetch --save git+https://nossa.ee/~talya/libpcre.zig
```

Then add the following to `build.zig` (a source build of `pcre` will be linked against automatically):

```zig
const pcre_pkg = b.dependency("libpcre.zig", .{ .optimize = optimize, .target = target });
const pcre_mod = pcre_pkg.module("libpcre");
exe.root_module.addImport("pcre", pcre_mod);
```

To link against the system `libpcre`, add the `system_library` build option like this:

Note, only the following systems support this mode:
* Linux: `apt install pkg-config libpcre3-dev`
* macOS: `brew install pkg-config pcre`
* ~~Windows: install [vcpkg](https://github.com/microsoft/vcpkg#quick-start-windows), `vcpkg integrate install`, `vcpkg install pcre --triplet x64-windows-static`~~

  Zig doesn't have vcpkg integration any more. Suggestions welcome!

```zig
const pcre_pkg = b.dependency("libpcre.zig", .{ .optimize = optimize, .target = target, .system_library = "true" });
```

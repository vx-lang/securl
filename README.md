# curl-vx

The curl command-line tool, rewritten in [Vx](https://github.com/vx-lang/Vx). This first version
speaks HTTP/1.1 only, and it implements the options that curl users use most.

The goal is to show what Vx's type system buys a network tool:

- **No trusted code in the protocol code, checked by the compiler.** The package `curlvx` holds
  the URL parser, the command-line parser, the request builder, the response parser, chunked
  decoding and redirects. It is compiled with `--no-trusted-code curlvx`, so any `unsafe`,
  `extern`, `mlir!`, `extern impl` or `unsafe impl` in it is a compile error.
- **Capabilities.** Only `main` gets the rights of the program (`fn main(root : Root)`). It gives
  the network right (`&Network`) to the transfer and keeps the file right (`&Files`) for itself.
  The parsers get neither, so a bug in a parser cannot open a file or a socket. The compiler
  checks this: the code has no other way to reach the operating system.

## Status (2026-11-25)

Measured with curl's own test suite: curl's `runtests.pl` and its test servers, pointed at
`build/curl-vx` with `-c`. The tests come from curl commit 2f5c657, and the compiler is vxc from
Vx main d3ed6cf0b.

| Test set | Passed |
|---|---|
| All tests with the keyword `HTTP` that runtests.pl runs for an HTTP-only tool | 393 of 787 (50%) |
| The HTTP tests that use only options curl-vx implements (`tests/supported-tests.txt`) | 340 of 423 (80%) |
| Unit tests (`tests/unit`) | 3 of 3 |

`vxc --audit` (`make audit`) lists the trusted code of the program:

| Part | Lines | Trusted code |
|---|---|---|
| `src/curlvx/` (the package with all protocol code) | about 3,400 | none, and `--no-trusted-code` enforces this |
| `src/main.vx`, `src/disk.vx` | about 450 | none |
| `src/sys/` (shims for what `std` lacks) | 147 | 3 `extern` functions, 8 `unsafe` blocks |

`core` and `std` have trusted code too: the audit counts 965 `unsafe` blocks and 77 `extern`
functions in the modules that the program uses. That is the trusted base of the language, as
Rust's `std` is for a Rust program.

### A fair comparison with the Rust rewrite

The Rust rewrite [kov/curl](https://github.com/kov/curl) counts 3,711 uses of `unsafe`, of which
2,871 are `unsafe` blocks. Its own write-up says that its core, tool and backend crates have none.
Most of them are in its C ABI shim (a drop-in `libcurl.so`) and in the wrappers of OpenSSL and
other C libraries. curl-vx has neither a C ABI nor TLS yet. So the counts do not compare one to
one. Also, Rust's `#![forbid(unsafe_code)]` does what `--no-trusted-code` does.

What Rust does not have is the capability check. In Rust, any function can call
`std::fs::File::open` or `std::net::TcpStream::connect`. In curl-vx, the type system keeps the
parsers away from the disk and the network.

## Build

You need a `vxc` built from Vx main (the capability types are recent), and its `libvx_std_core`.

```sh
make                                      # builds build/curl-vx
make VXDIST=/path/to/dir/with/vxc         # another toolchain
make audit                                # lists the trusted code
./tests/unit/run.sh                       # unit tests
```

## Run curl's test suite

```sh
git clone --depth 1 https://github.com/curl/curl ~/curl-src
cd ~/curl-src
cmake -B build -DCURL_ENABLE_SSL=OFF -DCURL_USE_LIBPSL=OFF -DUSE_LIBIDN2=OFF \
  -DCURL_ZLIB=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF -DUSE_NGHTTP2=OFF \
  -DCURL_USE_LIBSSH2=OFF -DCURL_DISABLE_LDAP=ON -DBUILD_TESTING=ON
cmake --build build -j8 && cmake --build build --target testdeps -j8
cd ~/curl-vx
make test CURL_SRC=~/curl-src                             # every HTTP test
make test CURL_SRC=~/curl-src TESTS="$(cat tests/supported-tests.txt)"
```

`curl-vx --version` says `Protocols: http`, so runtests.pl skips the tests of other protocols
and of features such as TLS, cookies files or compression.

## Options

`-A` `-b` (a cookie string) `-d` `--data-ascii` `--data-raw` `--data-binary` `--data-urlencode`
`--json` `-D` `-e` (with `;auto`) `-f` `--fail-with-body` `-G` `-H` (with the `name:` and
`name;` forms) `-I` `-i` `-k` `-L` `--location-trusted` `--max-redirs` `-o` `-O`
`--remote-name-all` `--output-dir` `-r` `-s` `-S` `-T` `-u` `-v` `-w` (most variables, `%header{}`,
`%output{}`, `%{stderr}`) `-X` `-x` `-U` `--noproxy` `--resolve` `--connect-to` `--path-as-is`
`--raw` `-0` `--url` `-h` `-V`, and the options that runtests.pl adds: `-q` `--trace-ascii`
`--trace-time`.

The 2025 curl user survey asked for each user's favourite option. curl-vx accepts 18 of the top
20 answers. It does not have `--libcurl` and `-F`. `-vv` and `-vvv` work as `-v`, `-k` changes
nothing until curl-vx has TLS, and `-w` has no time variables yet.

## Not done yet

In order of how much users need them:

1. **HTTPS.** 98.7% of curl users use it. Vx has no TLS. The choices are a small trusted wrapper
   around a C library (OpenSSL or rustls-ffi), or TLS written in Vx.
1. Timeouts (`-m`, `--connect-timeout`). `std::sync::wait::within` can bound a read. Nothing
   bounds `TcpStream::connect` yet.
1. Connection reuse, URL globbing (`{a,b}` and `[1-9]`), the cookie engine (`-c`, cookie
   files), `-F` multipart forms, `--digest`, `--next`, `-C` resume, `-K` config files,
   `http_proxy` and `NO_PROXY` variables (Vx has no safe way to read the environment).
1. HTTP/2, HTTP/3 and compression (`--compressed`).

## Vx issues found while writing curl-vx

- `std::io::stdout_write` writes through Rust's line buffer, and nothing flushes it when a Vx
  program ends. The bytes after the last newline are lost. `src/sys/console.vx` calls `write(2)`
  directly instead.
- Compile time grows about 2x with each link of an `else if` chain: 24 links take 6.8 s, and 50
  links did not finish. The slow step is after the parser (`--action print-ast` is already slow).
  `options.vx` uses flat `if .. { return }` blocks instead.
- `--audit` and `--no-trusted-code` blame the `unsafe` block of a trait's default method
  (`core::fmt::Write::write_c_str`) on the file that writes the `impl`.
- No safe way to make a `String` from bytes, to write a `Vec<u8>` to standard output, to read
  the command-line arguments (PR #3975 adds `root.args`), to copy the bytes of a string literal,
  or to read an environment variable. `src/sys/` wraps each of these.
- A loop that reassigned a `Url` variable (`u = next;`) got E4009 ("`u` is assigned while it is
  borrowed"), and smaller programs with the same shape compile. `fetch.vx` carries the URL as
  text instead. The cause is not known yet.
- Smaller things: `on` and `transfer` are keywords, adjacent string literals do not join,
  there is no `ref mut` pattern, and an `assert(false, ..)` fails at compile time even on a
  path that never runs.

## Layout

```
src/main.vx          the only code that gets `Root`; opens files, runs the transfers
src/disk.vx          reads and creates files; each function takes `&Files`
src/sys/             trusted shims: arguments, standard output, string literals
src/curlvx/          the protocol code; no trusted code
  options.vx           the command line
  url.vx               URLs and redirects
  http.vx              the request bytes, in libcurl's header order; the response head
  fetch.vx             one transfer: connect, send, read, follow redirects, proxies
  conn.vx              a TCP connection with a read buffer; needs `&Network`
  body.vx encode.vx    request bodies, Base64, URL encoding
  output.vx            standard output or a file that main opened
  writeout.vx          -w
tests/unit/          unit tests of the parsers
tests/run-curl-tests.sh   runs curl's runtests.pl against build/curl-vx
```

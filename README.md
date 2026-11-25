# curl-vx

The curl command-line tool, rewritten in [Vx](https://github.com/vx-lang/Vx). It speaks HTTP/1.1
and HTTPS, and it implements the options that curl users use most. TLS comes from OpenSSL, which
is a git submodule.

The goal is to show what Vx's type system buys a network tool:

- **No trusted code in the protocol code, checked by the compiler.** The package `curlvx` holds
  the URL parser, the command-line parser, the request builder, the response parser, chunked
  decoding, redirects and proxies. It is compiled with `--no-trusted-code curlvx`, so any
  `unsafe`, `extern`, `mlir!`, `extern impl` or `unsafe impl` in it is a compile error.
- **Capabilities.** Only `main` gets the rights of the program (`fn main(root : Root)`). It gives
  the network right (`&Network`) to the transfer and keeps the file right (`&Files`) for itself.
  It also loads the certificate authorities for TLS, because that reads files, and lends the
  result to the transfer. The parsers get no right, so a bug in a parser cannot open a file or
  a socket. The compiler checks this: the code has no other way to reach the operating system.

## Get it

```sh
git clone --recurse-submodules --shallow-submodules https://github.com/<you>/curl-vx
# or, in a clone without the submodule:
git submodule update --init --depth 1
```

## Build

You need a `vxc` built from Vx main (the capability types are recent), its runtime library
`libvx_std_core`, a C compiler and Perl (for OpenSSL). Put the paths in `config.mk`, which git
ignores:

```make
VXC       = /path/to/Vx/target/release/vxc
VX_LIBDIR = /path/to/Vx/target/release
LLVM_BIN  = /usr/lib/llvm-22/bin
# SYSTEM_OPENSSL = 1    # link the OpenSSL of the system, not the submodule
```

```sh
make            # builds OpenSSL once (build/openssl), then build/curl-vx
make audit      # lists the trusted code
make unit       # unit tests
make test-tls   # HTTPS and time-limit tests against local servers (needs python3)
```

## Status (2026-11-25)

Measured with curl's own test suite: curl's `runtests.pl` and its test servers, pointed at
`build/curl-vx` with `-c`. The tests come from curl commit 2f5c657, and the compiler is vxc from
Vx main d3ed6cf0b.

| Test set | Passed |
|---|---|
| All tests with the keyword `HTTP` that runtests.pl runs for curl-vx | 458 of 855 (54%) |
| The HTTP tests that use only options curl-vx implements (`tests/supported-tests.txt`) | 399 of 478 (83%) |
| TLS and time-limit tests against local servers (`tests/tls`) | 18 of 18 |
| Unit tests (`tests/unit`) | 4 of 4 |

runtests.pl skips 14 HTTPS tests here, because they need `stunnel`. The C build of the test
suite has OpenSSL, so that runtests.pl runs 61 more tests, most of them Digest tests (see "Run
curl's test suite"). Before Digest, curl-vx passed 409 of those 855.

`vxc --audit` (`make audit`) lists the trusted code of the program:

| Part | Lines | Trusted code |
|---|---|---|
| `src/curlvx/` (the package with all protocol code) | 4,655 | none, and `--no-trusted-code` enforces this |
| `src/main.vx`, `src/disk.vx` | 512 | none |
| `src/sys/` (OpenSSL calls, time limits of sockets, shims for what `std` lacks) | 827 | 37 `extern` functions, 51 `unsafe` blocks |

Of the trusted code in `src/sys/`, 77 of the 88 items are the OpenSSL bindings: TLS in `tls.vx`,
and the hash functions and random bytes of Digest in `hash.vx`.
`core` and `std` have trusted code too: the audit counts 965 `unsafe` blocks and 77 `extern`
functions in the modules that the program uses. That is the trusted base of the language, as
Rust's `std` is for a Rust program. OpenSSL itself is C.

### A fair comparison with the Rust rewrite

The Rust rewrite [kov/curl](https://github.com/kov/curl) counts 3,711 uses of `unsafe`, of which
2,871 are `unsafe` blocks. Its own write-up says that its core, tool and backend crates have none.
Most of them are in its C ABI shim (a drop-in `libcurl.so`) and in the wrappers of OpenSSL and
other C libraries. curl-vx has no C ABI, and it uses only the part of OpenSSL that a TLS client
needs. So the counts do not compare one to one. Also, Rust's `#![forbid(unsafe_code)]` does what
`--no-trusted-code` does.

What Rust does not have is the capability check. In Rust, any function can call
`std::fs::File::open` or `std::net::TcpStream::connect`. In curl-vx, the type system keeps the
parsers away from the disk and the network.

## HTTPS

`src/sys/tls.vx` calls OpenSSL. It checks the certificate of the server and its host name or IP
address, as curl does, with TLS 1.2 at least, SNI and ALPN `http/1.1`. It trusts the certificate
authorities of the system: the first bundle that it finds in the usual places of Linux and
macOS, and the paths that OpenSSL knows, including `SSL_CERT_FILE` and `SSL_CERT_DIR`.
`--cacert` and `--capath` name others, and `-k` turns the check off. An `https://` URL through
an HTTP proxy uses a CONNECT tunnel. The exit codes are curl's: 60 for a certificate problem, 35
for a failed handshake, and 77 for a file of certificate authorities that cannot be read.

## Time limits

`-m` limits the whole transfer, redirects included. `--connect-timeout` limits the connect, the
CONNECT of a proxy and the TLS handshake, and is 300 seconds by default, as in libcurl. Both
give exit code 28 with curl's messages: `Connection timed out after N milliseconds`, or
`Operation timed out after N milliseconds with B out of T bytes received`. The lookup of a host
name has no time limit yet.

`curlvx` turns each limit into a deadline (`std::time::Instant`) for the connection. A socket
call in `src/sys/tls.vx` runs in `std::sync::wait::within` until that deadline, so the runtime
of Vx ends the wait. The TLS code polls in slices of 20 ms and checks the clock between them.
`within` takes a closure. The calls are in `src/sys` and not in `curlvx` only because of a Vx
bug (below).

## Authentication

`-u` sends Basic credentials, as curl does by default. With `--digest`, the first request goes
without credentials, and a POST or a PUT goes with an empty body, as a probe. The 401 brings
the challenge, and the request goes again with the Digest response: MD5, SHA-256 and
SHA-512/256, their `-sess` variants, `qop=auth` and `auth-int`, `userhash`, and the nonce
count. `--anyauth` takes Digest when the server offers it, and else Basic. `--proxy-digest`
and `--proxy-anyauth` do the same with an HTTP proxy and its 407.

`src/curlvx/auth.vx` holds all of it, as libcurl's `http.c` and `vauth/digest.c` do it, with no
trusted code. Only the hash functions and the random client nonce come from OpenSSL, through
`src/sys/hash.vx`. The unit tests check the examples of RFC 2617 and RFC 7616.

## Run curl's test suite

runtests.pl asks curl's own `curlinfo` program which hash functions the C build has, and skips
the Digest tests when it has none. So the C build needs a crypto library. `make openssl-dev`
installs the OpenSSL of the submodule for it:

```sh
make openssl-dev       # prints the -DOPENSSL_ROOT_DIR for cmake
git clone --depth 1 https://github.com/curl/curl ~/curl-src
cd ~/curl-src
cmake -B build -DCURL_ENABLE_SSL=ON -DCURL_USE_OPENSSL=ON -DOPENSSL_USE_STATIC_LIBS=ON \
  -DOPENSSL_ROOT_DIR=$HOME/curl-vx/build/openssl-dev/usr/local \
  -DCURL_USE_LIBPSL=OFF -DUSE_LIBIDN2=OFF -DCURL_ZLIB=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF \
  -DUSE_NGHTTP2=OFF -DCURL_USE_LIBSSH2=OFF -DCURL_DISABLE_LDAP=ON -DBUILD_TESTING=ON
cmake --build build -j8 && cmake --build build --target testdeps -j8
cd ~/curl-vx
make test CURL_SRC=~/curl-src              # every HTTP test
make test-supported CURL_SRC=~/curl-src    # the tests in tests/supported-tests.txt
```

`curl-vx --version` says `Protocols: http https`, so runtests.pl skips the tests of other
protocols and of features such as cookie files or compression.
`tests/scan-supported-tests.py` lists the tests that use only options curl-vx has, and the
missing options that block the most tests.

## Options

`-A` `-b` (a cookie string) `-d` `--data-ascii` `--data-raw` `--data-binary` `--data-urlencode`
`--json` `-D` `-e` (with `;auto`) `-f` `--fail-with-body` `-G` `-H` (with the `name:` and
`name;` forms) `-I` `-i` `-k` `--cacert` `--capath` `-L` `--location-trusted` `--max-redirs`
`-o` `-O` `--remote-name-all` `--output-dir` `-r` `-s` `-S` `-T` `-u` `--digest` `--basic`
`--anyauth` `-v` `-w` (most variables, `%header{}`, `%output{}`, `%{stderr}`) `-X` `-x` `-U`
`--proxy-digest` `--proxy-basic` `--proxy-anyauth` `--noproxy` `--resolve` `--connect-to`
`--path-as-is` `--raw` `-0` `--url` `-m` `--connect-timeout` `-h` `-V`, and the options that
runtests.pl adds: `-q` `--trace-ascii` `--trace-time`.

The 2025 curl user survey asked for each user's favourite option. curl-vx accepts 18 of the top
20 answers. It does not have `--libcurl` and `-F`. `-vv` and `-vvv` work as `-v`, and `-w` has no
time variables yet.

## Not done yet

In order of how much users need them:

1. HTTP/2 (73% of survey users), connection reuse, compression (`--compressed`).
1. URL globbing (`{a,b}` and `[1-9]`), the cookie engine (`-c`, cookie files), `-F` multipart
   forms, `--next`, `-J`, `-C` resume, `-K` config files, `--netrc`, `http_proxy` and
   `NO_PROXY` variables (Vx has no safe way to read the environment), HTTPS proxies, and
   Digest with the proxy of a CONNECT tunnel.
1. HTTP/3.

## Vx issues found while writing curl-vx

The Vx project tracks these.

- [#4000](https://github.com/vx-lang/Vx/issues/4000) `std::io::stdout_write` writes through
  Rust's line buffer, and nothing flushes it when a Vx program ends. The bytes after the last
  newline are lost. `src/sys/console.vx` calls `write(2)` directly instead.
- [#3998](https://github.com/vx-lang/Vx/issues/3998) Compile time grows about 2x with each link
  of an `else if` chain: 24 links take 6.8 s, and 50 links did not finish. `options.vx` uses
  flat `if .. { return }` blocks instead.
- [#3999](https://github.com/vx-lang/Vx/issues/3999) `--audit` and `--no-trusted-code` blame the
  `unsafe` block of a trait's default method (`core::fmt::Write::write_c_str`) on the file that
  writes the `impl`.
- [#4005](https://github.com/vx-lang/Vx/issues/4005) No safe way to make a `String` from bytes,
  to write a `Vec<u8>` to standard output, to copy the bytes of a string literal, or to read an
  environment variable. Vx PR #3975 adds `root.args`. `src/sys/` wraps each of these.
- [#4001](https://github.com/vx-lang/Vx/issues/4001) The flat code generator declines `?` on a
  `Result` of a struct with an `Option` field, so curl-vx compiles through the older AST path.
- [#4002](https://github.com/vx-lang/Vx/issues/4002), [#4003](https://github.com/vx-lang/Vx/issues/4003),
  [#4004](https://github.com/vx-lang/Vx/issues/4004): a reference cannot be pointed at another
  field, `assert(false, ..)` fails at compile time on a path that never runs, and there is no
  `ref mut` pattern or `Option::as_mut`.
- [#4010](https://github.com/vx-lang/Vx/issues/4010) In a loop, `info.url_effective =
  url_text(&u);` makes the checker think that `info` borrows `u`, so a later `u = next;` gets
  E4009. The result of `url_text` holds no reference. `fetch.vx` carries the URL as text
  instead. Binding the result first (`let t = url_text(&u); info.url_effective = t;`) also
  works.
- [#4092](https://github.com/vx-lang/Vx/issues/4092) `--no-trusted-code` takes the body of each
  closure for an `unsafe` block (E5003), while `--audit` lists nothing for it. So `curlvx`
  cannot pass a closure to `std::sync::wait::within`, and `src/sys/tls.vx` holds those calls.

## License

curl-vx uses curl's license (SPDX `curl`), an MIT-style license, as curl does. See `LICENSE`.
It keeps curl's copyright notice, because curl-vx takes its help text, its messages and its
behavior from curl.

A curl-vx binary also holds code under other licenses:

- OpenSSL, under the Apache License 2.0 (`third_party/openssl/LICENSE.txt`). By default the
  Makefile links it statically, so a copy of the binary must come with that license.
- The Vx runtime `libvx_std_core`, under the Apache License 2.0 with LLVM Exceptions.

## Layout

```
src/main.vx          the only code that gets `Root`; opens files, loads the TLS settings
src/disk.vx          reads and creates files; each function takes `&Files`
src/sys/             trusted code: OpenSSL (tls.vx), arguments, standard output, literals
src/curlvx/          the protocol code; no trusted code
  options.vx           the command line
  url.vx               URLs and redirects
  http.vx              the request bytes, in libcurl's header order; the response head
  fetch.vx             one transfer: connect, TLS, send, read, redirects, proxies
  conn.vx              a connection with a read buffer; needs `&Network`
  body.vx encode.vx    request bodies, Base64, URL encoding
  output.vx            standard output or a file that main opened
  writeout.vx          -w
third_party/openssl  OpenSSL 3.5.9 (LTS), a shallow git submodule
LICENSE              curl's license, with the copyright of curl-vx and of curl
tests/unit/          unit tests of the parsers
tests/tls/           HTTPS tests against local servers, with test certificates
tests/run-curl-tests.sh   runs curl's runtests.pl against build/curl-vx
```

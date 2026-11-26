# securl

The curl command-line tool, rewritten in [Vx](https://github.com/vx-lang/Vx). It speaks HTTP/1.1,
HTTP/2 and HTTPS, and it implements the options that curl users use most. TLS comes from OpenSSL,
which is a git submodule. HTTP/2 is written in Vx.

The goal is to show what Vx's type system buys a network tool:

- **No trusted code outside one small package, checked by the compiler.** The package `securl`
  holds the URL parser, the command-line parser, the request builder, the response parser,
  chunked decoding, redirects and proxies. The package `cli` holds the tool around it, and
  `disk` its files. They are compiled with `--no-trusted-code`, so any `unsafe`, `extern`,
  `mlir!`, `extern impl` or `unsafe impl` in them is a compile error. All trusted code is in
  `sys`. `src/main.vx`, the one file outside a package, only hands `Root` to `cli`.
- **Capabilities.** Only `main` gets the rights of the program (`fn main(root : Root)`), and it
  hands them to `cli::tool_main`. That gives the network right (`&Network`) to the transfer and
  keeps the file right (`&Files`) for itself. It also loads the certificate authorities for TLS,
  because that reads files, and lends the result to the transfer. With the environment right
  (`&Environment`) it reads the proxy variables, such as `https_proxy`, and gives the transfer
  their values, not the right. The parsers get no right, so
  a bug in a parser cannot open a file or a socket: the compiler checks that the protocol code
  has no other way to the disk or the network. It can still use standard input, output and
  error, through `sys::console`, with no right. A right for them in `Root` would close that
  gap, but that is a change in Vx's `std`.

## Get it

```sh
git clone --recurse-submodules --shallow-submodules https://github.com/vx-lang/securl
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
make            # builds OpenSSL once (build/openssl), then build/securl
make audit      # lists the trusted code, and checks that no code outside src/sys makes a raw pointer
make unit       # unit tests
make test-tls   # HTTPS and time-limit tests against local servers (needs python3)
make test-h2    # HTTP/2 tests against a local server (makes a virtualenv with h2 from PyPI)
```

## Status (2026-11-26)

Measured with curl's own test suite: curl's `runtests.pl` and its test servers, pointed at
`build/securl` with `-c`. The tests come from curl commit 2f5c657, and the compiler is vxc from
Vx main 860f9f31a.

| Test set | Passed |
|---|---|
| The tests with the keyword `HTTP` that run the curl tool, as runtests.pl runs them for securl | 414 of 743 (55%) |
| The HTTP tests that use only options securl implements (`tests/supported-tests.txt`) | 377 of 453 (83%) |
| TLS, client-certificate, proxy, compression, socket-option and limit tests against local servers (`tests/tls`) | 117 of 117 |
| HTTP/2 tests against a local server built on python-hyper's `h2` (`tests/h2`) | 32 of 32 |
| Unit tests (`tests/unit`) | 9 of 9 |

`CURL=/path/to/curl tests/tls/run.sh` runs the checks of `tests/tls` against another curl, and
`tests/h2/run.sh` takes `CURL` too. curl 8.23.1-DEV, built from the same curl commit, passes all
TLS checks but one, which it skips: curl reads the extension of a chunk-size line with no limit
and waits for `-m`, while securl stops after 100 KiB. curl 8.18 with nghttp2 passes all HTTP/2
checks, with the same exit codes. It skips four that look for securl's own messages, where
curl gives the error texts of nghttp2.

Some HTTP tests have the keyword `libtest` or `unittest`. For those, runtests.pl runs a C
program of the curl build, linked with curl's own libcurl, so they never run securl.
`tests/run-curl-tests.sh` and `tests/scan-supported-tests.py` leave them out. Until 2026-11-26
the counts above included them by mistake: 152 of them passed, and the table said 522 of 874.
Test 1070 depends on timing: it passes in about one run of four, with and without recent
changes.

The C build of the test suite has OpenSSL, so that runtests.pl runs the Digest tests (see "Run
curl's test suite"). `stunnel` and `nghttpx` let it run its HTTPS and HTTP/2 tests too.

`vxc --audit` (`make audit`) lists the trusted code of the program:

| Part | Lines | Trusted code |
|---|---|---|
| `src/securl/` (the package with all protocol code) | 10,567 | none, and `--no-trusted-code` enforces this |
| `src/cli/` (the tool) and `src/disk/` (its files) | 701 | none, and `--no-trusted-code` enforces this |
| `src/main.vx` (hands `Root` to `cli`) | 11 | none. `--no-trusted-code` names only packages, but `make audit` lists any |
| `src/sys/` (OpenSSL calls, socket options, name lookup and time limits, shims for what `std` lacks) | 1,302 | 45 `extern` functions, 76 `unsafe` blocks |

Of the trusted code in `src/sys/`, 96 of the 121 items are the OpenSSL bindings: TLS (with the
ALPN choice for HTTP/2) in `tls.vx`, and the hash functions and random bytes of Digest in
`hash.vx`.
Two safe functions of `sys` read through a raw pointer with no check, `lit` and `push_lit`,
because a Vx string literal is a `*const i8` with no length yet
([Vx#532](https://github.com/vx-lang/Vx/issues/532)). They are correct for a literal. So that a
literal stays the only pointer that the other packages can have, `tools/check-no-pointers.sh`
refuses `as_mut_ptr`, `as_ptr`, pointer casts and `core::ptr` outside `src/sys`. Each build,
`make audit` and the GitHub workflow in `.github/workflows/checks.yml` run it.

`core` and `std` have trusted code too: the audit counts 978 `unsafe` blocks and 83 `extern`
functions in the modules that the program uses. That is the trusted base of the language, as
Rust's `std` is for a Rust program. OpenSSL itself is C.

### A fair comparison with the Rust rewrite

The Rust rewrite [kov/curl](https://github.com/kov/curl) counts 3,711 uses of `unsafe`, of which
2,871 are `unsafe` blocks. Its own write-up says that its core, tool and backend crates have none.
Most of them are in its C ABI shim (a drop-in `libcurl.so`) and in the wrappers of OpenSSL and
other C libraries. securl has no C ABI, and it uses only the part of OpenSSL that a TLS client
needs. So the counts do not compare one to one. Also, Rust's `#![forbid(unsafe_code)]` does what
`--no-trusted-code` does.

What Rust does not have is the capability check. In Rust, any function can call
`std::fs::File::open` or `std::net::TcpStream::connect`. In securl, the type system keeps the
parsers away from the disk and the network.

## HTTPS

`src/sys/tls.vx` calls OpenSSL. It checks the certificate of the server and its host name or IP
address, as curl does, with TLS 1.2 at least, SNI and ALPN `http/1.1`. It trusts the certificate
authorities of the system: the first bundle that it finds in the usual places of Linux and
macOS, and the paths that OpenSSL knows, including `SSL_CERT_FILE` and `SSL_CERT_DIR`.
`--cacert` and `--capath` name others, and `-k` turns the check off. `--cert` (with a password
after a `:` as in curl), `--key` and `--pass` give a client certificate in PEM or DER, with
libcurl's messages and exit codes (58, or 43 for a key that does not load). A TLS 1.3 server
that wants a certificate refuses after the handshake; securl reads its alert, as curl does,
and gives exit 56 with "tlsv13 alert certificate required". An `https://` URL through
an HTTP proxy uses a CONNECT tunnel, and so does an `http://` URL with `-p`. The exit codes are curl's: 60 for a certificate problem, 35
for a failed handshake, and 77 for a file of certificate authorities that cannot be read.

## Time limits

`-m` limits the whole transfer, redirects included. `--connect-timeout` limits the connect, the
CONNECT of a proxy and the TLS handshake, and is 300 seconds by default, as in libcurl. Both
give exit code 28 with curl's messages: `Connection timed out after N milliseconds`, or
`Operation timed out after N milliseconds with B out of T bytes received`. The lookup of a host
name has no time limit yet.

The package `securl` turns each limit into a deadline (`std::time::Instant`) for the connection.
Each socket call runs in `std::sync::wait::within` until that deadline, so the runtime of Vx
ends the wait: the connect in `src/securl/conn.vx`, and the reads and writes of a plain
connection in `src/sys/tls.vx`, which holds the TCP stream of a TLS connection too. The TLS code
polls in slices of 20 ms and checks the clock between them.

## HTTP/2

securl speaks HTTP/2 (RFC 9113) over TLS when the server takes it with ALPN, as curl does by
default, and over plain TCP with `--http2-prior-knowledge`. `--http1.1` turns it off. All of it
is in `src/securl/`, with no trusted code; only the ALPN choice comes from OpenSSL:

- `hpack.vx`: HPACK (RFC 7541) with the Huffman code and the dynamic table. Its tables come
  from the text of the RFC (`tools/gen-hpack-tables.py`), and a unit test decodes all the
  examples of its Appendix C.
- `h2.vx`: the frames, SETTINGS, PING, GOAWAY, RST_STREAM, CONTINUATION, padding, trailers, and
  flow control in both directions: a window of 1 MiB for the server, and the body of a request
  within the windows of the server. The request is the HTTP/1.1 request of `http.vx` turned
  into HTTP/2 fields, so authentication, cookies and `-H` work the same on both versions. The
  response head looks like curl's: `HTTP/2 200 ` and the header names in lower case.

curl's own HTTP/2 tests run through `nghttpx` (see "Run curl's test suite"). `tests/h2` tests
more of the protocol against a server built on the `h2` package of python-hyper, an independent
implementation. securl also fetches real sites over HTTP/2, such as Cloudflare's 1.3 MB home
page.

## Compression

`--compressed` asks for `deflate, gzip` and decodes them as the body arrives.
`src/securl/inflate.vx` is a DEFLATE decoder in Vx with the gzip and zlib wrappers, so this
needs no zlib and no trusted code. It follows libcurl and zlib: the CRC-32 and Adler-32 checks,
zlib's error texts after "Error while processing content unencoding: ", raw DEFLATE for a
`deflate` body that has no zlib header, a chain of up to five encodings, and exit 61 for a body
that ends inside the compressed data. `-w %{size_delivered}` gives the decoded size.
`--tr-encoding` sends `TE: gzip` and `Connection: TE`, and decodes the transfer codings of the
response before its content codings, with libcurl's rules: at most five, and chunked last.
`tests/unit/inflate.vx` feeds data from Python's zlib in one piece and one byte at a time, so
that each block header and symbol is cut once. A curl 8.23.1-DEV built with zlib passes the
compression checks of `tests/tls` too.

## Authentication

`-u` sends Basic credentials, as curl does by default. With `--digest`, the first request goes
without credentials, and a POST or a PUT goes with an empty body, as a probe. The 401 brings
the challenge, and the request goes again with the Digest response: MD5, SHA-256 and
SHA-512/256, their `-sess` variants, `qop=auth` and `auth-int`, `userhash`, and the nonce
count. `--anyauth` takes Digest when the server offers it, and else Basic. `--proxy-digest`
and `--proxy-anyauth` do the same with an HTTP proxy and its 407.

`src/securl/auth.vx` holds all of it, as libcurl's `http.c` and `vauth/digest.c` do it, with no
trusted code. Only the hash functions and the random client nonce come from OpenSSL, through
`src/sys/hash.vx`. The unit tests check the examples of RFC 2617 and RFC 7616.

## Cookies

`-b` with a file name, or `-c`, turns on the cookie engine, a port of libcurl's `cookie.c` in
`src/securl/cookie.vx`. It reads Netscape cookie files and `Set-Cookie:` lines, takes the
`Set-Cookie` headers of each response, redirects included, and sends the cookies that match the
host, the path and the security of each request, in libcurl's order. It follows libcurl's rules
for `domain`, `path`, `secure`, `httponly`, `max-age` and `expires` (with a port of libcurl's
date parser in `src/securl/date.vx`), the `__Secure-` and `__Host-` prefixes, and the limits.
`-c` writes the jar in the Netscape format at the end. Without libpsl, as in a libcurl without
it, a cookie for a domain with no dot is refused.

## Run curl's test suite

runtests.pl asks curl's own `curlinfo` program which hash functions the C build has, and skips
the Digest tests when it has none. So the C build needs a crypto library. `make openssl-dev`
installs the OpenSSL of the submodule for it:

```sh
make openssl-dev       # prints the -DOPENSSL_ROOT_DIR for cmake
git clone --depth 1 https://github.com/curl/curl ~/curl-src
cd ~/curl-src
cmake -B build -DCURL_ENABLE_SSL=ON -DCURL_USE_OPENSSL=ON -DOPENSSL_USE_STATIC_LIBS=ON \
  -DOPENSSL_ROOT_DIR=$HOME/securl/build/openssl-dev/usr/local \
  -DCURL_USE_LIBPSL=OFF -DUSE_LIBIDN2=OFF -DCURL_ZLIB=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF \
  -DUSE_NGHTTP2=OFF -DCURL_USE_LIBSSH2=OFF -DCURL_DISABLE_LDAP=ON -DBUILD_TESTING=ON
cmake --build build -j8 && cmake --build build --target testdeps -j8
cd ~/securl
tools/build-test-tools.sh                  # optional: nghttpx and stunnel, see below
make test CURL_SRC=~/curl-src              # every HTTP test
make test-supported CURL_SRC=~/curl-src    # the tests in tests/supported-tests.txt
```

runtests.pl runs its HTTP/2 tests through `nghttpx` and its HTTPS tests through `stunnel`.
pip cannot install either, so `tools/build-test-tools.sh` builds them from source (with
`libev` and `c-ares` for `nghttpx`) into the virtualenv `build/h2-venv`, against the OpenSSL of
the submodule. It checks each download against a SHA-256, and puts nothing into the system.
`tests/run-curl-tests.sh` finds them there.

`securl --version` says `Protocols: http https`, so runtests.pl skips the tests of other
protocols and of features such as compression.
`tests/scan-supported-tests.py` lists the tests that use only options securl has, and the
missing options that block the most tests.

## Options

`-A` `-b` (a cookie string or a cookie file) `-c` `-j` `-d` `--data-ascii` `--data-raw`
`--data-binary` `--data-urlencode`
`--json` `-F` (with `@file`, `<file`, `type=`, `filename=` and `headers=`) `--form-string`
`--form-escape` `-D` `-e` (with `;auto`) `-f` `--fail-with-body` `-G` `-H` (with the `name:` and
`name;` forms) `-I` `-i` `-k` `--cacert` `--capath` `-E` (`--cert`) `--cert-type` `--key` `--key-type` `--pass` `-L` `--location-trusted` `--max-redirs`
`-o` `-O` `--remote-name-all` `--output-dir` `-r` `-s` `-S` `-T` `-u` `--digest` `--basic`
`--anyauth` `-v` `-w` (most variables, `%header{}`, `%{header_json}`, `%output{}`, `%{stderr}`)
`-X` `-x` `-U` `-p` `--proxytunnel` `--socks4` `--socks4a` `--socks5` `--socks5-hostname`
`--proxy-digest` `--proxy-basic` `--proxy-anyauth` `--noproxy` `--resolve` `--connect-to`
`--path-as-is` `--raw` `-0` `--http1.1` `--http2` `--http2-prior-knowledge` `--url` `-m`
`--connect-timeout` `--compressed` `--tr-encoding` `--keepalive` `--keepalive-time` `--keepalive-cnt` `--tcp-nodelay` `-h`
`-V`, and the options that runtests.pl adds: `-q` `--trace-ascii` `--trace-time`.

As libcurl does, each connection sets TCP_NODELAY and TCP keepalive: the first probe after 60
seconds with no traffic, then one each 60 seconds, and 9 probes with no answer drop the
connection. `--keepalive-time` sets both times, `--keepalive-cnt` the probes, and
`--no-keepalive` and `--no-tcp-nodelay` turn them off. `src/sys/socket.vx` calls `setsockopt`,
because `std::net::TcpStream` has no socket options.

Without `-x`, the proxy comes from the environment, as in libcurl: `https_proxy` or
`HTTPS_PROXY` for HTTPS, `http_proxy` for HTTP, and then `all_proxy` or `ALL_PROXY`. As libcurl
does, securl does not read `HTTP_PROXY` in upper case, which a CGI program gets from the
`Proxy:` header of any request. `--noproxy`, or else `no_proxy` or `NO_PROXY`, lists the hosts
that go direct, and `-x ""` turns the variables off. `-v` says which variable it used.

A proxy URL with the scheme `socks4`, `socks4a`, `socks5` or `socks5h`, or the options
`--socks4`, `--socks4a`, `--socks5` and `--socks5-hostname`, name a SOCKS proxy.
`src/securl/socks.vx` speaks the protocols as libcurl does, with its messages and exit code 97,
and the user name and password of RFC 1929 for SOCKS5. SOCKS4a and SOCKS5h send the host name to
the proxy. SOCKS4 and SOCKS5 send its address, so securl looks the name up: with `--resolve`, or
as libcurl does for `localhost` (::1 first, then 127.0.0.1), or else with `getaddrinfo` in
`src/sys/socket.vx`, which takes the network right. `std` has no lookup of its own yet.

The 2025 curl user survey asked for each user's favourite option. securl accepts 19 of the top
20 answers. It does not have `--libcurl`. `-vv` and `-vvv` work as `-v`, and `-w` has no
time variables yet.

## Not done yet

In order of how much users need them:

1. Connection reuse (and with it, HTTP/2 multiplexing), brotli and zstd for `--compressed`,
   the
   `Upgrade: h2c` of `--http2` on plain HTTP, and HTTP/2 through an HTTP proxy.
1. URL globbing (`{a,b}` and `[1-9]`), `--next`, `-J`, `-C` resume, `-K` config files,
   `--netrc`, `-4` and `-6`, several files in one `-F` field, nested multipart forms and `-F`
   encoders, `--preproxy`, SOCKS5 with GSS-API, HTTPS proxies, Digest with the proxy of a
   CONNECT tunnel, and client certificates in PKCS#12 files or from engines and providers.
1. HTTP/3.

## Vx issues found while writing securl

The Vx project tracks these. Vx main has fixed #4000 (with #4025), #4010 (with #4026), #3999
(with #4028) and #4092 (with #4094), and securl no longer works around them.

- [#3998](https://github.com/vx-lang/Vx/issues/3998) Compile time grew about 2x with each link
  of an `else if` chain. `options.vx` uses flat `if .. { return }` blocks. Vx #4024 fixed it,
  and the flat blocks stay because they read as well.
- [#4005](https://github.com/vx-lang/Vx/issues/4005) No safe way to make a `String` from bytes,
  to write a `Vec<u8>` to standard output, to copy the bytes of a string literal, or to read an
  environment variable. Vx PR #3975 adds `root.args`. `src/sys/` wraps each of these.
- [#4001](https://github.com/vx-lang/Vx/issues/4001) The flat code generator declines `?` on a
  `Result` of a struct with an `Option` field, so securl compiles through the older AST path.
- [#4002](https://github.com/vx-lang/Vx/issues/4002), [#4003](https://github.com/vx-lang/Vx/issues/4003),
  [#4004](https://github.com/vx-lang/Vx/issues/4004): a reference cannot be pointed at another
  field, `assert(false, ..)` fails at compile time on a path that never runs, and there is no
  `ref mut` pattern or `Option::as_mut`.

## License

securl uses curl's license (SPDX `curl`), an MIT-style license, as curl does. See `LICENSE`.
It keeps curl's copyright notice, because securl takes its help text, its messages and its
behavior from curl.

A securl binary also holds code under other licenses:

- OpenSSL, under the Apache License 2.0 (`third_party/openssl/LICENSE.txt`). By default the
  Makefile links it statically, so a copy of the binary must come with that license.
- The Vx runtime `libvx_std_core`, under the Apache License 2.0 with LLVM Exceptions.

## Layout

```
src/main.vx          gets `Root`, and hands it to cli::tool_main
src/cli/tool.vx      the tool: the command line, the transfers, opening files, the TLS settings
src/disk/files.vx    reads and creates files; each function takes `&Files`
src/sys/             trusted code: OpenSSL (tls.vx), arguments, standard output, literals
src/securl/          the protocol code; no trusted code
  options.vx           the command line
  url.vx               URLs and redirects
  http.vx              the request bytes, in libcurl's header order; the response head
  fetch.vx             one transfer: connect, TLS, send, read, redirects, proxies
  conn.vx              a connection with a read buffer; needs `&Network`
  body.vx encode.vx    request bodies, Base64, URL encoding
  output.vx            standard output or a file that main opened
  writeout.vx          -w
third_party/openssl  OpenSSL 3.5.9 (LTS), a shallow git submodule
LICENSE              curl's license, with the copyright of securl and of curl
tests/unit/          unit tests of the parsers
tests/tls/           HTTPS tests against local servers, with test certificates
tests/run-curl-tests.sh   runs curl's runtests.pl against build/securl
tools/check-no-pointers.sh  refuses code that makes a raw pointer outside src/sys
```

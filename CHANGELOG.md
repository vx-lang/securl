# Changes

## 0.1.0 (2026-11-27)

The first release of securl: the curl command-line tool, rewritten in Vx, for HTTP/1.1, HTTP/2
and HTTPS.

### What it does

- The options that curl users use most: 19 of the top 20 answers of the 2025 curl user survey
  (not `--libcurl`). README.md lists them all.
- HTTP/1.1 and HTTP/2 (with ALPN, and with `--http2-prior-knowledge`), HTTPS with OpenSSL,
  client certificates, HSTS, cookies, Basic and Digest, `--compressed` (gzip, deflate, brotli
  and zstd, all decoded in Vx), redirects, HTTP, HTTPS and SOCKS proxies, `--unix-socket`,
  `--resolve` and `--connect-to`, `--retry`, `-C`, `-J`, `--next`, `-K`, URL globbing, and
  `-w` with its variables and timers.
- Connection reuse, as libcurl does it, with one type for the settings that decide it.

### How it is checked

- No trusted code outside the package `sys`: the protocol code, the tool and its files are
  compiled with `--no-trusted-code`. `make audit` lists the 135 trusted items of `sys`, 129 of
  them the OpenSSL bindings.
- Capabilities: only `main` has the rights of the program, and the parsers get none.
- Credentials are bound to the place they may go to, and only `auth.vx` reads a password
  (`tools/check-secrets.sh` checks this until Vx fields have levels).
- curl's own test suite, from curl commit 2f5c657: 599 of the 762 HTTP tests that run the
  tool, and 539 of the 569 that use only options securl has. 290 TLS, proxy and limit checks
  against local servers, which curl 8.23 passes too, 32 HTTP/2 checks, 13 unit tests, and
  libFuzzer on 9 parsers.

### Build

securl needs a vxc built from Vx main 98e8df6d5, with LLVM 22 and MLIR. OpenSSL 3.5 is a git
submodule. README.md says how to build. Only Linux on x86-64 has been built and tested.

### Not done yet

- Reuse of HTTP/2 connections and multiplexing, `Upgrade: h2c`, HTTP/2 through a proxy, and
  HTTP/3.
- `--variable`, `--no-clobber`, `-R`, `--netrc`, a default `.curlrc`, `-4` and `-6`, the
  progress meter and `-#`, `--preproxy`, Digest with the proxy of a CONNECT tunnel, and client
  certificates in PKCS#12 files. README.md has the whole list.
- `-w %{time_namelookup}` does not hold the name lookup, which happens inside the connect of
  Vx's `std::net`; `%{time_connect}` holds it.
- The 30 supported curl tests that fail are in `tests/supported-known-failures.txt`.

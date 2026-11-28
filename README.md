# securl

The curl command-line tool, rewritten in [Vx](https://github.com/vx-lang/Vx), for HTTP/1.1,
HTTP/2 and HTTPS. TLS comes from OpenSSL, a git submodule. Everything else is Vx.

## Why Vx

- **No trusted code outside `src/sys`.** The protocol code, the tool and its file access compile
  with `--no-trusted-code`. `make audit` lists the 135 trusted items left, 129 of them OpenSSL.
- **Capabilities.** Only `main` holds the rights to the network, the files, the environment and
  the terminal, and it hands each to the code that needs it. The parsers get none.
- **Types for curl's common bugs.** A connection is reused only when its whole `ConnKey`
  matches, and a password goes only where its `Credential` is bound.

## Build

```sh
curl -fsSL https://vxlang.org/install.sh | VX_VERSION=v0.0.6 sh    # Vx, into ~/.vx
git clone --recurse-submodules --shallow-submodules https://github.com/vx-lang/securl
cd securl && make
build/securl https://example.com/
```

You also need a C compiler and Perl. For a vxc built from source, set `VXC`, `VX_LIBDIR` and
`LLVM_BIN` in `config.mk`. Only Linux on x86-64 is tested.

## Status

| Tests | Passed |
|---|---|
| curl's HTTP tests, from curl 2f5c657 (`make test`) | 670 of 762 |
| The ones that use only options securl has (`make test-supported`) | 605 of 632 |
| TLS, proxy and limit tests (`make test-tls`) | 290 of 290 |
| HTTP/2 tests (`make test-h2`) | 32 of 32 |
| Unit tests (`make unit`) | 14 of 14 |
| libFuzzer on 11 parsers (`make fuzz`) | no crash in 50 million inputs |

[docs/testing.md](docs/testing.md) says how to run curl's test suite.

## Features

- **HTTPS:** OpenSSL 3.5, certificate checks, client certificates, and HTTPS proxies.
- **HTTP/2:** over TLS with ALPN, or with `--http2-prior-knowledge`. HPACK is in Vx.
- **Connection reuse:** as libcurl, with up to 5 idle connections.
- **Compression:** gzip, deflate, brotli and zstd, all decoded in Vx.
- **Authentication:** Basic and Digest, for servers and proxies.
- **Cookies and HSTS:** libcurl's cookie engine, `-b`, `-c` and `--hsts`.
- **Globbing:** `{a,b}` and `[1-9]` in URLs, and `#1` in `-o`.

[docs/options.md](docs/options.md) lists every option.

## Not done yet

- HTTP/2 connection reuse, `Upgrade: h2c`, HTTP/2 through a proxy, and HTTP/3.
- `-4` and `-6`, the progress meter, and PKCS#12 certificates.
- `%{time_namelookup}` holds no DNS time: Vx's `std::net` resolves inside its connect.

## Layout

```
src/securl/   the protocol code, with no trusted code
src/cli/      the tool, and src/disk/ its files
src/sys/      the trusted code: OpenSSL, socket options, string literals
tests/        unit, TLS, HTTP/2 and fuzz tests, and the curl test runner
tools/        build checks and fuzz scripts
```

[docs/vx-issues.md](docs/vx-issues.md) lists the Vx issues found on the way, and
[CHANGELOG.md](CHANGELOG.md) the releases.

## License

curl's license (SPDX `curl`), in `LICENSE`. A binary also holds OpenSSL (Apache 2.0), the Vx
runtime (Apache 2.0 with LLVM Exceptions), and brotli's dictionary (MIT).

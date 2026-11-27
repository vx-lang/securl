# Changes

## 0.1.0 (2026-11-27)

The first release: the curl tool, rewritten in Vx, for HTTP/1.1, HTTP/2 and HTTPS.

- **Features:** 19 of the top 20 options of the 2025 curl survey, HTTP/2, HTTPS with client
  certificates, proxies, cookies, HSTS, Basic and Digest, compression, connection reuse,
  globbing and `-w` timers. [docs/options.md](docs/options.md) lists every option.
- **Checks:** no trusted code outside `src/sys` (135 items, 129 of them OpenSSL), capabilities
  for the network, files and terminal, and credentials bound to where they may go.
- **Tests:** 599 of 762 of curl's HTTP tests (539 of 569 supported), 290 local checks, 32
  HTTP/2 checks, 13 unit tests, and libFuzzer on 9 parsers.
- **Build:** Vx main 98e8df6d5, LLVM 22, and OpenSSL 3.5 as a submodule. Only Linux on x86-64
  is tested.
- **Not done:** HTTP/2 reuse, h2c, HTTP/3, `--netrc`, `--variable`, the progress meter, and
  PKCS#12 certificates. The failing supported tests are in `tests/supported-known-failures.txt`.

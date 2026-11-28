# Changes

## Unreleased

- **Conditional requests:** `-z` with a date, `--etag-save` and `--etag-compare`, as in curl. A
  304 never makes an output file.
- **`.netrc`:** `-n`, `--netrc-optional` and `--netrc-file`, with the entry for each host bound
  to that host. libFuzzer on the netrc parser too.
- **Variables:** `--variable` and `--expand-OPTION`, with curl's functions.
- **Requests:** `--follow`, `--post301`, `--post302`, `--post303`, `--request-target`,
  `--url-query`, `--fail-early`, `--disallow-username-in-url` and `--oauth2-bearer`.
- **Protocol:** `--proxy-header`, `--proxy1.0`, `--http0.9`, `--ignore-content-length`,
  `--proto-default`, and the wait for `100 Continue` with `--expect100-timeout`.

## 0.1.0 (2026-11-27)

The first release: the curl tool, rewritten in Vx, for HTTP/1.1, HTTP/2 and HTTPS.

- **Features:** 19 of the top 20 options of the 2025 curl survey, HTTP/2, HTTPS with client
  certificates, proxies, cookies, HSTS, Basic and Digest, compression, connection reuse,
  globbing and `-w` timers. [docs/options.md](docs/options.md) lists every option.
- **Checks:** no trusted code outside `src/sys` (135 items, 129 of them OpenSSL), capabilities
  for the network, files and terminal, and credentials bound to where they may go.
- **Tests:** 599 of 762 of curl's HTTP tests (539 of 569 supported), 290 local checks, 32
  HTTP/2 checks, 13 unit tests, and libFuzzer on 9 parsers.
- **Build:** Vx v0.0.6, which carries LLVM 22, and OpenSSL 3.5 as a submodule. Only Linux on
  x86-64 is tested.
- **Not done:** HTTP/2 reuse, h2c, HTTP/3, `--netrc`, `--variable`, the progress meter, and
  PKCS#12 certificates. The failing supported tests are in `tests/supported-known-failures.txt`.

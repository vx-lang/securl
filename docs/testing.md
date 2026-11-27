# Testing

## curl's test suite

runtests.pl needs curl's C build for its test servers. The build needs OpenSSL, so that the
Digest tests run:

```sh
make openssl-dev       # prints the -DOPENSSL_ROOT_DIR for cmake
git clone https://github.com/curl/curl ~/curl-src && git -C ~/curl-src checkout 2f5c657
cd ~/curl-src
cmake -B build -DCURL_ENABLE_SSL=ON -DCURL_USE_OPENSSL=ON -DOPENSSL_USE_STATIC_LIBS=ON \
  -DOPENSSL_ROOT_DIR=$HOME/securl/build/openssl-dev/usr/local \
  -DCURL_USE_LIBPSL=OFF -DUSE_LIBIDN2=OFF -DCURL_ZLIB=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF \
  -DUSE_NGHTTP2=OFF -DCURL_USE_LIBSSH2=OFF -DCURL_DISABLE_LDAP=ON -DBUILD_TESTING=ON
cmake --build build -j8 && cmake --build build --target testdeps -j8
cd ~/securl
tools/build-test-tools.sh                  # stunnel and nghttpx, for the HTTPS and HTTP/2 tests
make test CURL_SRC=~/curl-src              # every HTTP test
make test-supported CURL_SRC=~/curl-src    # the tests that use only options securl has
```

The runs leave out the `libtest` and `unittest` tests, which never run securl.
`tests/supported-known-failures.txt` lists the supported tests that fail today. Test 1070
depends on timing, and passes in some runs.

## Local tests

`make test-tls` and `make test-h2` run securl against local servers. `CURL=/path/to/curl
tests/tls/run.sh` runs the same checks against another curl; curl 8.23 passes them too.

## Fuzzing

`make fuzz FUZZ_TIME=60` runs libFuzzer on 9 parsers. vxc has no fuzzer option, so
`tools/build-fuzzers.sh` goes through LLVM: vxc emits MLIR, `mlir-translate` makes LLVM IR, and
clang adds libFuzzer. A Vx panic shows as a crash, and its input stays in `build/fuzz`.

## CI

`.github/workflows/build.yml` builds securl, runs the audit and the unit, TLS, HTTP/2 and fuzz
tests, and the supported curl tests. A failure not in the known list fails the run.

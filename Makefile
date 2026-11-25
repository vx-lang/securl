# Build curl-vx.
#
#   make            build build/curl-vx
#   make audit      list each use of trusted code (unsafe, extern) in the program
#   make unit       run the unit tests in tests/unit
#   make test       run curl's own test suite against build/curl-vx (see README.md)
#   make test-supported   only the curl tests that use options curl-vx has
#   make test-tls   the HTTPS tests against local servers (needs python3)
#
# curl-vx needs a vxc built from Vx main. Put the settings of your machine in config.mk, which
# git ignores. For example:
#
#   VXC       = /path/to/Vx/target/release/vxc
#   VX_LIBDIR = /path/to/Vx/target/release
#   LLVM_BIN  = /opt/homebrew/opt/llvm@22/bin

-include config.mk

VXC       ?= vxc
# The folder that holds libvx_std_core, the runtime of Vx programs.
VX_LIBDIR ?= $(HOME)/.vx/current/lib
# vxc runs the LLVM tools, such as mlir-translate, from PATH.
LLVM_BIN  ?= /usr/lib/llvm-22/bin
CURL_SRC  ?= $(HOME)/curl-src
JOBS      ?= 4

# TLS comes from OpenSSL. By default the Makefile builds the OpenSSL of the submodule
# third_party/openssl as static libraries. Set SYSTEM_OPENSSL = 1 in config.mk to link the
# OpenSSL of the system instead.
OPENSSL_SRC   = third_party/openssl
OPENSSL_BUILD = build/openssl
OPENSSL_STAMP = $(OPENSSL_BUILD)/.built
ifeq ($(SYSTEM_OPENSSL),1)
  TLS_DEPS =
  TLS_LIBS = -lssl -lcrypto
else
  TLS_DEPS = $(OPENSSL_STAMP)
  TLS_LIBS = $(OPENSSL_BUILD)/libssl.a $(OPENSSL_BUILD)/libcrypto.a -ldl -lpthread
endif

# `curlvx` may not hold trusted code: the compiler refuses any `unsafe`, `extern`, `mlir!`,
# `extern impl` or `unsafe impl` in it. All trusted code lives in the small `sys` package.
PKGS = --package sys=src/sys --package curlvx=src/curlvx --no-trusted-code curlvx

SRCS = $(wildcard src/*.vx src/sys/*.vx src/curlvx/*.vx)
LIBS = -L $(VX_LIBDIR) -lvx_std_core -Wl,-rpath,$(VX_LIBDIR)

all: build/curl-vx

build/curl-vx: $(SRCS) $(TLS_DEPS)
	@mkdir -p build
	PATH="$(LLVM_BIN):$$PATH" $(VXC) $(PKGS) -c src/main.vx -o build/curl-vx.o
	cc build/curl-vx.o $(TLS_LIBS) $(LIBS) -o $@

audit:
	PATH="$(LLVM_BIN):$$PATH" $(VXC) $(PKGS) --audit src/main.vx

unit:
	VXC="$(VXC)" VX_LIBDIR="$(VX_LIBDIR)" LLVM_BIN="$(LLVM_BIN)" ./tests/unit/run.sh

test: build/curl-vx
	./tests/run-curl-tests.sh $(CURL_SRC) $(TESTS)

# The TLS tests, against local servers with the test certificates in tests/tls/certs.
test-tls: build/curl-vx
	./tests/tls/run.sh

# The HTTP tests that use only options that curl-vx has (tests/scan-supported-tests.py).
test-supported: build/curl-vx
	./tests/run-curl-tests.sh $(CURL_SRC) $$(cat tests/supported-tests.txt)

# OpenSSL builds once, out of its source tree, with only what a TLS client needs.
$(OPENSSL_STAMP):
	@test -f $(OPENSSL_SRC)/Configure || \
	  { echo "OpenSSL is missing. Run: git submodule update --init --depth 1"; exit 1; }
	@mkdir -p $(OPENSSL_BUILD)
	cd $(OPENSSL_BUILD) && perl $(CURDIR)/$(OPENSSL_SRC)/Configure \
	  no-shared no-tests no-docs no-apps no-module no-dso no-engine > configure.log
	$(MAKE) -C $(OPENSSL_BUILD) -j$(JOBS) build_libs > $(OPENSSL_BUILD)/build.log
	@touch $@

openssl: $(TLS_DEPS)

# `clean` keeps the OpenSSL build, which takes minutes. `distclean` removes it too.
clean:
	rm -rf build/curl-vx build/curl-vx.o build/unit

distclean:
	rm -rf build

.PHONY: all audit unit test test-supported test-tls clean distclean openssl

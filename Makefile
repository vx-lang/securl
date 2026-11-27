# Build securl.
#
#   make            build build/securl
#   make audit      list each use of trusted code (unsafe, extern) in the program
#   make unit       run the unit tests in tests/unit
#   make test       run curl's own test suite against build/securl (see README.md)
#   make test-supported   only the curl tests that use options securl has
#   make test-tls   the HTTPS tests against local servers (needs python3)
#   make test-h2    the HTTP/2 tests against a local server (needs python3 and the h2 package)
#
# securl needs a vxc built from Vx main. Put the settings of your machine in config.mk, which
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

# Only `sys` may hold trusted code. The compiler refuses any `unsafe`, `extern`, `mlir!`,
# `extern impl` or `unsafe impl` in the other packages: `securl` (the protocol code), `cli`
# (the tool) and `disk` (its files). src/main.vx, outside any package, only calls `cli`.
PKGS = --package sys=src/sys --package securl=src/securl --package disk=src/disk \
  --package cli=src/cli --no-trusted-code securl --no-trusted-code disk --no-trusted-code cli

SRCS = $(wildcard src/*.vx src/sys/*.vx src/securl/*.vx src/disk/*.vx src/cli/*.vx)
LIBS = -L $(VX_LIBDIR) -lvx_std_core -Wl,-rpath,$(VX_LIBDIR)

all: build/securl

build/securl: $(SRCS) $(TLS_DEPS)
	@mkdir -p build
	tools/check-no-pointers.sh
	tools/check-secrets.sh
	PATH="$(LLVM_BIN):$$PATH" $(VXC) $(PKGS) -c src/main.vx -o build/securl.o
	cc build/securl.o $(TLS_LIBS) $(LIBS) -o $@

# The trusted code of the program, the check that the code with no trusted code makes no raw
# pointer (tools/check-no-pointers.sh), and the check that only auth.vx sends a password
# (tools/check-secrets.sh).
audit:
	tools/check-no-pointers.sh
	tools/check-secrets.sh
	PATH="$(LLVM_BIN):$$PATH" $(VXC) $(PKGS) --audit src/main.vx

unit: $(TLS_DEPS)
	VXC="$(VXC)" VX_LIBDIR="$(VX_LIBDIR)" LLVM_BIN="$(LLVM_BIN)" TLS_LIBS="$(TLS_LIBS)" \
	  ./tests/unit/run.sh

test: build/securl
	./tests/run-curl-tests.sh $(CURL_SRC) $(TESTS)

# The TLS tests, against local servers with the test certificates in tests/tls/certs.
test-tls: build/securl
	./tests/tls/run.sh

# The HTTP/2 tests, against a server built on the h2 package (made in build/h2-venv).
test-h2: build/securl
	./tests/h2/run.sh

# The HTTP tests that use only options that securl has (tests/scan-supported-tests.py).
test-supported: build/securl
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

# The headers and static libraries of the OpenSSL build, installed under build/openssl-dev, for
# building curl's own test suite with a crypto library (README.md, "Run curl's test suite").
OPENSSL_DEV = build/openssl-dev
openssl-dev: $(OPENSSL_STAMP)
	$(MAKE) -C $(OPENSSL_BUILD) install_dev DESTDIR=$(CURDIR)/$(OPENSSL_DEV) > $(OPENSSL_BUILD)/install.log
	@echo "OpenSSL for cmake: -DOPENSSL_ROOT_DIR=$(CURDIR)/$(OPENSSL_DEV)/usr/local"

# `clean` keeps the OpenSSL build, which takes minutes. `distclean` removes it too.
clean:
	rm -rf build/securl build/securl.o build/unit

distclean:
	rm -rf build

.PHONY: all audit unit test test-supported test-tls test-h2 clean distclean openssl openssl-dev

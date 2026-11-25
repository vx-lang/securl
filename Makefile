# Build curl-vx with a vxc built from the top of Vx main.
#
#   make            build build/curl-vx
#   make audit      list each use of trusted code (unsafe, extern) in the program
#   make test       run curl's own test suite (tests/data) against build/curl-vx
#
# VXDIST holds `vxc` and `libvx_std_core`. CURL_SRC is a checkout of github.com/curl/curl
# that was built with cmake, so that its test servers exist (see README.md).

VXDIST   ?= /mnt/scratch/curl-vx-toolchain/dist
VXC      ?= $(VXDIST)/vxc
LLVM_BIN ?= /usr/lib/llvm-22/bin
CURL_SRC ?= $(HOME)/curl-src

# `curlvx` may not hold trusted code: the compiler refuses any `unsafe`, `extern`, `mlir!`,
# `extern impl` or `unsafe impl` in it. All trusted code lives in the small `sys` package.
PKGS = --package sys=src/sys --package curlvx=src/curlvx --no-trusted-code curlvx

SRCS = $(wildcard src/*.vx src/sys/*.vx src/curlvx/*.vx)

all: build/curl-vx

build/curl-vx: $(SRCS)
	@mkdir -p build
	PATH="$(LLVM_BIN):$$PATH" $(VXC) $(PKGS) -c src/main.vx -o build/curl-vx.o
	cc build/curl-vx.o -L $(VXDIST) -lvx_std_core -Wl,-rpath,$(VXDIST) -o $@

audit:
	PATH="$(LLVM_BIN):$$PATH" $(VXC) $(PKGS) --audit src/main.vx

test: build/curl-vx
	./tests/run-curl-tests.sh $(CURL_SRC) $(TESTS)

clean:
	rm -rf build

.PHONY: all audit test clean

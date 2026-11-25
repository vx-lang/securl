# Build curl-vx.
#
#   make            build build/curl-vx
#   make audit      list each use of trusted code (unsafe, extern) in the program
#   make unit       run the unit tests in tests/unit
#   make test       run curl's own test suite against build/curl-vx (see README.md)
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

# `curlvx` may not hold trusted code: the compiler refuses any `unsafe`, `extern`, `mlir!`,
# `extern impl` or `unsafe impl` in it. All trusted code lives in the small `sys` package.
PKGS = --package sys=src/sys --package curlvx=src/curlvx --no-trusted-code curlvx

SRCS = $(wildcard src/*.vx src/sys/*.vx src/curlvx/*.vx)
LIBS = -L $(VX_LIBDIR) -lvx_std_core -Wl,-rpath,$(VX_LIBDIR)

all: build/curl-vx

build/curl-vx: $(SRCS)
	@mkdir -p build
	PATH="$(LLVM_BIN):$$PATH" $(VXC) $(PKGS) -c src/main.vx -o build/curl-vx.o
	cc build/curl-vx.o $(LIBS) -o $@

audit:
	PATH="$(LLVM_BIN):$$PATH" $(VXC) $(PKGS) --audit src/main.vx

unit:
	VXC="$(VXC)" VX_LIBDIR="$(VX_LIBDIR)" LLVM_BIN="$(LLVM_BIN)" ./tests/unit/run.sh

test: build/curl-vx
	./tests/run-curl-tests.sh $(CURL_SRC) $(TESTS)

clean:
	rm -rf build

.PHONY: all audit unit test clean

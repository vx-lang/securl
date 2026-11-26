#!/usr/bin/env python3
"""Write tests/unit/inflate.vx: data that Python's zlib compresses, for the decoders of
src/securl/inflate.vx, and data that they must refuse with zlib's texts.

    python3 tools/gen-inflate-test.py > tests/unit/inflate.vx
"""
import random
import struct
import zlib

random.seed(7)
WORDS = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu".split()
TEXT_SMALL = b"hello hello hello hello world\n" * 3
TEXT_BIG = (" ".join(random.choice(WORDS) for _ in range(900)) + "\n").encode()


def raw(data, level=9):
    c = zlib.compressobj(level, zlib.DEFLATED, -15)
    return c.compress(data) + c.flush()


def gz(data, level=9, name=None, comment=None, extra=None):
    flags = 0
    if extra is not None:
        flags |= 4
    if name is not None:
        flags |= 8
    if comment is not None:
        flags |= 16
    out = b"\x1f\x8b\x08" + bytes([flags]) + b"\0\0\0\0\0\xff"
    if extra is not None:
        out += struct.pack("<H", len(extra)) + extra
    if name is not None:
        out += name + b"\0"
    if comment is not None:
        out += comment + b"\0"
    out += raw(data, level)
    out += struct.pack("<II", zlib.crc32(data) & 0xffffffff, len(data) & 0xffffffff)
    return out


CASES = [
    ("gzip, fixed codes", "WRAP_GZIP", gz(TEXT_SMALL), TEXT_SMALL),
    ("gzip, dynamic codes", "WRAP_GZIP", gz(TEXT_BIG), TEXT_BIG),
    ("gzip, stored blocks", "WRAP_GZIP", gz(TEXT_BIG, 0), TEXT_BIG),
    ("gzip with FEXTRA, FNAME and FCOMMENT", "WRAP_GZIP",
     gz(TEXT_SMALL, 6, b"f.txt", b"a comment", b"XYZW"), TEXT_SMALL),
    ("zlib, dynamic codes", "WRAP_ZLIB", zlib.compress(TEXT_BIG, 9), TEXT_BIG),
    ("zlib, stored", "WRAP_ZLIB", zlib.compress(TEXT_SMALL, 0), TEXT_SMALL),
    ("raw DEFLATE sent as deflate", "WRAP_ZLIB", raw(TEXT_BIG), TEXT_BIG),
    ("raw DEFLATE", "WRAP_RAW", raw(TEXT_SMALL), TEXT_SMALL),
]

_bad = gz(TEXT_SMALL)
BAD_CRC = _bad[:-8] + bytes([_bad[-8] ^ 1]) + _bad[-7:]
ERRORS = [
    ("a bad gzip magic", "WRAP_GZIP", b"\x1f\x8c" + gz(TEXT_SMALL)[2:], "incorrect header check"),
    ("a bad CRC", "WRAP_GZIP", BAD_CRC, "incorrect data check"),
    ("a bad block type", "WRAP_RAW", b"\x07\x00", "invalid block type"),
    ("two gzip members", "WRAP_GZIP", gz(TEXT_SMALL) + gz(TEXT_SMALL),
     "Multi-member gzip response not supported"),
]

HEAD = '''// Checks the DEFLATE, gzip and zlib decoders of securl::inflate with data from Python's zlib,
// fed whole and one byte at a time, so that each symbol and header can be cut. Made by
// tools/gen-inflate-test.py.
import core::result;
import std::vec;
import sys::text;
import securl::bytes;
import securl::inflate;

fn unhex(s : *const i8) -> Vec<u8> {
  let h = lit(s);
  let mut out = Vec<u8>::new();
  let mut i = 0;
  while i + 1 < h.len() {
    out.push((hex_value(h.get(i)) * 16 + hex_value(h.get(i + 1))) as u8);
    i = i + 2;
  }
  return out;
}

/// The output of a decoder of `wrap` for `data`, fed in pieces of `step` bytes. `ok` says
/// whether it took all pieces, `done` whether the data ended, and `error` why it failed.
fn run(wrap : i32, data : &Vec<u8>, step : i32, ok : &mut bool, done : &mut bool,
error : &mut Vec<u8>) -> Vec<u8> {
  let mut d = new_inflate(wrap);
  let mut out = Vec<u8>::new();
  let mut i = 0;
  *ok = true;
  while i < data.len() {
    let mut end = i + step;
    if end > data.len() {
      end = data.len();
    }
    match d.feed(&range_of(data, i, end)) {
      Result<Vec<u8>, i32>::Ok(part) => {
        append(&mut out, &part);
      },
      Result<Vec<u8>, i32>::Err(_e) => {
        *ok = false;
        *error = clone_bytes(&d.error);
        return out;
      }
    }
    i = end;
  }
  *done = d.complete();
  return out;
}

/// Whether `data` decodes to `want`, fed one byte at a time and fed whole.
fn decodes(wrap : i32, data : *const i8, want : *const i8) -> bool {
  let input = unhex(data);
  let expected = unhex(want);
  let mut step = 1;
  while step <= input.len() {
    let mut ok = false;
    let mut done = false;
    let mut error = Vec<u8>::new();
    let got = run(wrap, &input, step, &mut ok, &mut done, &mut error);
    if !ok || !done || !same_bytes(&got, &expected) {
      return false;
    }
    if step == 1 {
      step = input.len();
    } else {
      step = input.len() + 1;
    }
  }
  return true;
}

/// Whether the decoder refuses `data` with `message`.
fn fails_with(wrap : i32, data : *const i8, message : *const i8) -> bool {
  let input = unhex(data);
  let mut ok = true;
  let mut done = false;
  let mut error = Vec<u8>::new();
  let _got = run(wrap, &input, input.len(), &mut ok, &mut done, &mut error);
  return !ok && eq_lit(&error, message);
}

fn main() -> i32 {'''


def main():
    lines = [HEAD]
    for name, wrap, data, want in CASES:
        lines.append(f'  assert(decodes({wrap}, "{data.hex()}",\n    "{want.hex()}"), "{name}");')
    for name, wrap, data, message in ERRORS:
        lines.append(f'  assert(fails_with({wrap}, "{data.hex()}",\n    "{message}"), "{name}");')
    cut = gz(TEXT_SMALL)[:-5]
    lines.append(f'''  // A body that ends inside the data is not complete.
  let mut ok = false;
  let mut done = true;
  let mut error = Vec<u8>::new();
  let _part = run(WRAP_GZIP, &unhex("{cut.hex()}"), 1000, &mut ok, &mut done, &mut error);
  assert(ok && !done, "a cut gzip body");''')
    lines.append("  return 0;\n}")
    print("\n".join(lines))


if __name__ == "__main__":
    main()

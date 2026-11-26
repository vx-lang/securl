#!/usr/bin/env python3
"""Write tests/unit/brotli_decode.vx: brotli streams made by the brotli library of the system
(libbrotlienc, through ctypes), with the length and the FNV-1a hash of what each decodes to, and
streams that must fail with libcurl's exit code. The test feeds each stream whole, a byte at a
time, and in pieces of 7 bytes.

    python3 tools/gen-brotli-test.py > tests/unit/brotli_decode.vx
"""
import ctypes
import random

enc = ctypes.CDLL("libbrotlienc.so.1")
enc.BrotliEncoderMaxCompressedSize.restype = ctypes.c_size_t
enc.BrotliEncoderMaxCompressedSize.argtypes = [ctypes.c_size_t]
enc.BrotliEncoderCompress.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_size_t,
                                      ctypes.c_char_p, ctypes.POINTER(ctypes.c_size_t),
                                      ctypes.c_char_p]


def compress(data, quality, lgwin=22, mode=0):
    n = max(enc.BrotliEncoderMaxCompressedSize(len(data)), 64)
    out = ctypes.create_string_buffer(n)
    size = ctypes.c_size_t(n)
    assert enc.BrotliEncoderCompress(quality, lgwin, mode, len(data), data, ctypes.byref(size),
                                     out)
    return out.raw[:size.value]


def fnv(data):
    h = 14695981039346656037
    for b in data:
        h = ((h ^ b) * 1099511628211) % (1 << 64)
    return h


random.seed(7932)
WORDS = [b"the", b"quick", b"brown", b"fox", b"jumps", b"over", b"lazy", b"dog", b"brotli",
         b"\n", b"<div>", b"</div>", b"return", b"HTTP/1.1"]


def text(n):
    out = bytearray()
    while len(out) < n:
        out += random.choice(WORDS) + b" "
    return bytes(out[:n])


# English, so that the encoder uses the static dictionary and its transforms: words with a
# capital letter, in capitals, and with the punctuation of the transforms after them.
PROSE = (b"The transfer of a web page often uses a compressed form. When the server knows that "
         b"the client can decode it, it sends the body in brotli, which has a dictionary of common "
         b"words. Such words, written in Capitals or in CAPITALS, come out of the dictionary with "
         b"a transform: \"quoted\", (in brackets), at the end of a sentence. A Decoder must apply "
         b"each one exactly. THE SAME TEXT IN UPPER CASE TESTS THE TRANSFORM OF ALL LETTERS, and "
         b"the Same Text With Capitals Tests The First Letter. Numbers like 1998 and 2026, "
         b"addresses like http://example.com/index.html, and lists: first, second; third.\n")
T = text(4000)
R = random.randbytes(1500)
GOOD = [
    ("one byte", b"a", compress(b"a", 11)),
    ("nothing", b"", compress(b"", 11)),
    ("text, quality 0", T, compress(T, 0)),
    ("text, quality 5", T, compress(T, 5)),
    ("text, quality 11", T, compress(T, 11)),
    ("text, a window of 1 KiB", T, compress(T, 11, 10)),
    ("English with the dictionary", PROSE, compress(PROSE, 11, 22, 1)),
    ("English, quality 5", PROSE, compress(PROSE, 5, 22, 1)),
    ("zeros", bytes(3000), compress(bytes(3000), 9)),
    ("random bytes", R, compress(R, 11)),
]
GOOD_FRAME = compress(PROSE, 11, 22, 1)
BAD = [
    # libcurl gives 61 for these.
    ("a flipped byte", GOOD_FRAME[:12] + bytes([GOOD_FRAME[12] ^ 0x40]) + GOOD_FRAME[13:], 61),
    # And its write error, 23, for bytes after the end of the stream.
    ("bytes after the end", GOOD_FRAME + b"junk", 23),
]
CUT = [
    ("a stream cut in half", GOOD_FRAME[:len(GOOD_FRAME) // 2]),
    ("a stream without its last byte", GOOD_FRAME[:-1]),
]

print('''// Checks securl::brotli against streams that libbrotli made, fed whole, a byte at a time, and
// in pieces of 7 bytes. Made by tools/gen-brotli-test.py.
import core::num;
import core::result;
import std::vec;
import sys::text;
import securl::brotli;
import securl::bytes;

fn hex_value(c : u8) -> i32 {
  if c >= 97u8 {
    return (c as i32) - 87;
  }
  return (c as i32) - 48;
}

/// The bytes of the hex text `s`.
fn unhex(s : *const i8) -> Vec<u8> {
  let t = lit(s);
  let mut out = Vec<u8>::new();
  let mut i = 0;
  while i + 1 < t.len() {
    out.push((hex_value(t.get(i)) * 16 + hex_value(t.get(i + 1))) as u8);
    i = i + 2;
  }
  return out;
}

fn fnv(data : &Vec<u8>) -> u64 {
  let mut h : u64 = 14695981039346656037u64;
  for b in data.iter() {
    h = (h ^ (*b as u64)) * 1099511628211u64;
  }
  return h;
}

// What a decoding gave: 0 for a body that ended after the stream, the exit code of libcurl for an
// error, or 1 for a body that ended inside the stream.
struct Decoded {
  status : i32,
  out : Vec<u8>,
}

fn decode(data : &Vec<u8>, piece : i32) -> Decoded {
  let mut b = new_brotli();
  let mut out = Vec<u8>::new();
  let mut at = 0;
  while at < data.len() {
    let mut end = at + piece;
    if end > data.len() {
      end = data.len();
    }
    match b.feed(&range_of(data, at, end)) {
      Result<Vec<u8>, i32>::Ok(bytes) => {
        append(&mut out, &bytes);
      },
      Result<Vec<u8>, i32>::Err(code) => {
        return Decoded {
          status : code,
          out : out
        };
      }
    }
    at = end;
  }
  let mut status = 0;
  if !b.complete() {
    status = 1;
  }
  return Decoded {
    status : status,
    out : out
  };
}

fn decodes_to(stream : *const i8, length : i32, hash : u64) -> bool {
  let data = unhex(stream);
  let sizes = [1000000, 1, 7];
  let mut k = 0;
  while k < 3 {
    let d = decode(&data, sizes[k]);
    if d.status != 0 || d.out.len() != length || fnv(&d.out) != hash {
      return false;
    }
    k = k + 1;
  }
  return true;
}

fn ends_with(stream : *const i8, status : i32) -> bool {
  let data = unhex(stream);
  let sizes = [1000000, 1, 7];
  let mut k = 0;
  while k < 3 {
    if decode(&data, sizes[k]).status != status {
      return false;
    }
    k = k + 1;
  }
  return true;
}

fn main() -> i32 {''')
for name, raw, comp in GOOD:
    print(f'  assert(decodes_to("{comp.hex()}",\n    {len(raw)}, {fnv(raw)}u64), "{name}");')
for name, comp, code in BAD:
    print(f'  assert(ends_with("{comp.hex()}", {code}), "{name} fails with {code}");')
for name, comp in CUT:
    print(f'  assert(ends_with("{comp.hex()}", 1), "{name} is incomplete");')
print('''  return 0;
}''')

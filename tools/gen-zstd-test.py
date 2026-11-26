#!/usr/bin/env python3
"""Write tests/unit/zstd_decode.vx: zstd frames made by libzstd, through Python 3.14's
compression.zstd, with the length and the FNV-1a hash of what each decodes to, and frames that
must fail. The test feeds each frame whole, a byte at a time, and in pieces of 7 bytes.

    python3 tools/gen-zstd-test.py > tests/unit/zstd_decode.vx
"""
import random
import struct
from compression import zstd

random.seed(4120)
WORDS = [b"the", b"quick", b"brown", b"fox", b"jumps", b"over", b"lazy", b"dog", b"zstd", b"\n",
         b"HTTP/1.1", b"200", b"OK", b"Content-Encoding"]


def text(n):
    out = bytearray()
    while len(out) < n:
        out += random.choice(WORDS) + b" "
    return bytes(out[:n])


def frame(data, level, checksum=True):
    return zstd.compress(data, options={zstd.CompressionParameter.compression_level: level,
                                        zstd.CompressionParameter.checksum_flag: int(checksum)})


def streamed(data):
    # No content size in the header: the frame of a compressor that did not know it.
    c = zstd.ZstdCompressor(level=3)
    return c.compress(data) + c.flush()


def fnv(data):
    h = 14695981039346656037
    for b in data:
        h = ((h ^ b) * 1099511628211) % (1 << 64)
    return h


def with_dict_id(f):
    """The frame `f` with a 1-byte dictionary ID of 7 in its header."""
    desc = f[4]
    assert desc & 3 == 0
    at = 5 if desc & 0x20 else 6
    return f[:4] + bytes([desc | 1]) + f[5:at] + b"\x07" + f[at:]


T = text(3000)
R = random.randbytes(1500)
SKIP = struct.pack("<II", 0x184D2A53, 3) + b"abc"
GOOD = [
    ("one byte", b"a", frame(b"a", 3)),
    ("text, level 1", T, frame(T, 1)),
    ("text, level 19", T, frame(T, 19)),
    ("text, a fast level", T, frame(T, -5)),
    ("text, no checksum", T, frame(T, 9, checksum=False)),
    ("text, no content size", T, streamed(T)),
    ("zeros", bytes(2000), frame(bytes(2000), 3)),
    ("random bytes", R, frame(R, 3)),
    ("two frames and a skippable frame", T[:100] + T[100:900],
     frame(T[:100], 3) + SKIP + frame(T[100:900], 19)),
    ("an empty frame", b"", frame(b"", 3)),
]
TEXT_FRAME = frame(T, 19)
BAD = [
    ("a bad checksum", TEXT_FRAME[:-1] + bytes([TEXT_FRAME[-1] ^ 1])),
    ("an unknown magic number", b"\x28\xb5\x2f\xfe" + TEXT_FRAME[4:]),
    ("a frame after junk", TEXT_FRAME + b"junk"),
    ("a frame that names a dictionary", with_dict_id(frame(b"hello", 3))),
    ("a flipped byte in a block", TEXT_FRAME[:40] + bytes([TEXT_FRAME[40] ^ 0x55]) + TEXT_FRAME[41:]),
]
CUT = [
    ("a frame cut in its block", TEXT_FRAME[:len(TEXT_FRAME) // 2]),
    ("a frame without its checksum", TEXT_FRAME[:-4]),
]

print('''// Checks securl::zstd against frames that libzstd made, fed whole, a byte at a time, and in
// pieces of 7 bytes. Made by tools/gen-zstd-test.py.
import core::num;
import core::result;
import std::vec;
import sys::text;
import securl::bytes;
import securl::zstd;

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

// What a decoding gave: 0 for a body that ended after a frame, 1 for an error, 2 for a body that
// ended inside a frame.
struct Decoded {
  status : i32,
  out : Vec<u8>,
}

fn decode(data : &Vec<u8>, piece : i32) -> Decoded {
  let mut z = new_zstd();
  let mut out = Vec<u8>::new();
  let mut at = 0;
  while at < data.len() {
    let mut end = at + piece;
    if end > data.len() {
      end = data.len();
    }
    match z.feed(&range_of(data, at, end)) {
      Result<Vec<u8>, i32>::Ok(bytes) => {
        append(&mut out, &bytes);
      },
      Result<Vec<u8>, i32>::Err(_e) => {
        return Decoded {
          status : 1,
          out : out
        };
      }
    }
    at = end;
  }
  let mut status = 0;
  if !z.complete() {
    status = 2;
  }
  return Decoded {
    status : status,
    out : out
  };
}

fn decodes_to(frame : *const i8, length : i32, hash : u64) -> bool {
  let data = unhex(frame);
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

fn ends_with(frame : *const i8, status : i32) -> bool {
  let data = unhex(frame);
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
for name, comp in BAD:
    print(f'  assert(ends_with("{comp.hex()}", 1), "{name} fails");')
for name, comp in CUT:
    print(f'  assert(ends_with("{comp.hex()}", 2), "{name} is incomplete");')
print('''  return 0;
}''')

#!/usr/bin/env python3
"""Write src/securl/brotli_tables.vx: the static dictionary, the word transforms, the context
lookup table and the block length codes of brotli (RFC 7932, appendices A and B, and sections
7.1 and 6), read from the brotli library of the system, libbrotlicommon.

    python3 tools/gen-brotli-tables.py > src/securl/brotli_tables.vx

The data is from Google's brotli, under the MIT license, and is the same as in RFC 7932.
"""
import ctypes
import hashlib

# The SHA-256 of the dictionary of RFC 7932.
DICTIONARY_SHA256 = "20e42eb1b511c21806d4d227d07e5dd06877d8ce7b3a817f378f313653f35c70"

lib = ctypes.CDLL("libbrotlicommon.so.1")


class Dictionary(ctypes.Structure):
    _fields_ = [("size_bits_by_length", ctypes.c_uint8 * 32),
                ("offsets_by_length", ctypes.c_uint32 * 32),
                ("data_size", ctypes.c_size_t),
                ("data", ctypes.POINTER(ctypes.c_uint8))]


class Transforms(ctypes.Structure):
    _fields_ = [("prefix_suffix_size", ctypes.c_uint16),
                ("prefix_suffix", ctypes.POINTER(ctypes.c_uint8)),
                ("prefix_suffix_map", ctypes.POINTER(ctypes.c_uint16)),
                ("num_transforms", ctypes.c_uint32),
                ("transforms", ctypes.POINTER(ctypes.c_uint8)),
                ("params", ctypes.POINTER(ctypes.c_uint8)),
                ("cut_off_transforms", ctypes.c_int16 * 10)]


class PrefixCodeRange(ctypes.Structure):
    _fields_ = [("offset", ctypes.c_uint16), ("nbits", ctypes.c_uint8)]


lib.BrotliGetDictionary.restype = ctypes.POINTER(Dictionary)
lib.BrotliGetTransforms.restype = ctypes.POINTER(Transforms)
d = lib.BrotliGetDictionary().contents
t = lib.BrotliGetTransforms().contents
data = bytes(d.data[:d.data_size])
assert hashlib.sha256(data).hexdigest() == DICTIONARY_SHA256
assert t.num_transforms == 121
lookup = bytes((ctypes.c_uint8 * 2048).in_dll(lib, "_kBrotliContextLookupTable"))
ranges = (PrefixCodeRange * 26).in_dll(lib, "_kBrotliPrefixCodeRanges")

# Each transform as (prefix, type, suffix), from the length-prefixed strings of prefix_suffix.
ps = bytes(t.prefix_suffix[:t.prefix_suffix_size])


def string_at(index):
    at = t.prefix_suffix_map[index]
    return ps[at + 1:at + 1 + ps[at]]


triples = [(string_at(t.transforms[3 * i]), t.transforms[3 * i + 1],
            string_at(t.transforms[3 * i + 2])) for i in range(121)]
# Every prefix and suffix, each once, and the index of each in that list.
strings = sorted({s for p, _, x in triples for s in (p, x)})
index = {s: i for i, s in enumerate(strings)}


def vx_list(values, per_line=16):
    lines = []
    for i in range(0, len(values), per_line):
        lines.append(", ".join(str(v) for v in values[i:i + per_line]))
    return "[" + ",\n    ".join(lines) + "]"


def hex_pushes(name, blob, per=4096):
    out = []
    for i in range(0, len(blob), per):
        out.append(f'  push_brotli_hex(&mut {name}, "{blob[i:i + per].hex()}");')
    return "\n".join(out)


print(f'''// The tables of brotli (RFC 7932): the static dictionary (appendix A), the word transforms
// (appendix B), the context lookup table (section 7.1) and the block length codes (section 6).
// Made by tools/gen-brotli-tables.py from libbrotlicommon. The data is from Google's brotli,
// under the MIT license.
import std::vec;
import sys::text;

fn brotli_hex_digit(c : u8) -> i32 {{
  if c >= 97u8 {{
    return (c as i32) - 87;
  }}
  return (c as i32) - 48;
}}

/// Add the bytes of the hex text `s` to `out`.
fn push_brotli_hex(out : &mut Vec<u8>, s : *const i8) -> void {{
  let t = lit(s);
  let mut i = 0;
  while i + 1 < t.len() {{
    out.push((brotli_hex_digit(t.get(i)) * 16 + brotli_hex_digit(t.get(i + 1))) as u8);
    i = i + 2;
  }}
}}

/// The {len(data)} bytes of the static dictionary.
pub fn brotli_dictionary() -> Vec<u8> {{
  let mut d = Vec<u8>::with_capacity({len(data)});
{hex_pushes("d", data)}
  return d;
}}

/// Where the words of length `n` (4 to 24) start in the dictionary.
pub fn dictionary_offset(n : i32) -> i32 {{
  let offsets = {vx_list(list(d.offsets_by_length))};
  return offsets[n];
}}

/// The number of words of length `n` is 2 to this power.
pub fn dictionary_size_bits(n : i32) -> i32 {{
  let bits = {vx_list(list(d.size_bits_by_length))};
  return bits[n];
}}

/// The prefix of transform `i` (0 to 120), as an index for `transform_text`.
pub fn transform_prefix(i : i32) -> i32 {{
  let prefixes = {vx_list([index[p] for p, _, _ in triples])};
  return prefixes[i];
}}

/// The kind of transform `i`: 0 for the word as it is, 1 to 9 to drop that many bytes at the
/// end, 10 to make the first letter upper case, 11 to make all of them upper case, and 12 to 20
/// to drop 1 to 9 bytes at the start.
pub fn transform_kind(i : i32) -> i32 {{
  let kinds = {vx_list([k for _, k, _ in triples])};
  return kinds[i];
}}

/// The suffix of transform `i`, as an index for `transform_text`.
pub fn transform_suffix(i : i32) -> i32 {{
  let suffixes = {vx_list([index[x] for _, _, x in triples])};
  return suffixes[i];
}}

/// The prefix or suffix number `i`.
pub fn transform_text(i : i32) -> Vec<u8> {{
  let mut out = Vec<u8>::new();''')
for i, s in enumerate(strings):
    if s:
        print(f'  if i == {i} {{\n    push_brotli_hex(&mut out, "{s.hex()}");\n  }}')
print(f'''  return out;
}}

/// The context lookup table: for context mode `m`, the context of the literal after the bytes
/// p1 (the last) and p2 is `lookup[512 * m + p1] | lookup[512 * m + 256 + p2]`.
pub fn context_lookup() -> Vec<u8> {{
  let mut t = Vec<u8>::with_capacity(2048);
{hex_pushes("t", lookup)}
  return t;
}}

/// The first block length of block length code `c` (0 to 25), and its number of extra bits.
pub fn block_length_base(c : i32) -> i32 {{
  let bases = {vx_list([r.offset for r in ranges])};
  return bases[c];
}}

pub fn block_length_bits(c : i32) -> i32 {{
  let bits = {vx_list([r.nbits for r in ranges])};
  return bits[c];
}}''')

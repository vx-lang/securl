#!/usr/bin/env python3
"""Write tests/unit/hpack_rfc7541.vx from the examples of RFC 7541 Appendix C.

    python3 tools/gen-hpack-test.py rfc7541.txt tests/unit/hpack_rfc7541.vx
"""
import re, sys
raw = open(sys.argv[1]).read()
# Drop the page footers and headers of the RFC text, and the form feeds.
text = "\n".join(l for l in raw.replace("\f", "").splitlines()
                 if "[Page " not in l and not l.startswith("RFC 7541 "))
def section(start, end):
    # The headings of the body start a line; those of the table of contents are indented.
    return text[text.index("\n" + start):text.index("\n" + end)]
groups = [
    ("C.3.  Request Examples without Huffman Coding", "C.4.  Request Examples with Huffman Coding", 4096),
    ("C.4.  Request Examples with Huffman Coding", "C.5.  Response Examples without Huffman Coding", 4096),
    ("C.5.  Response Examples without Huffman Coding", "C.6.  Response Examples with Huffman Coding", 256),
    ("C.6.  Response Examples with Huffman Coding", "Acknowledgments", 256),
]
out = ["// Generated from RFC 7541 Appendix C by a script: each example is decoded with the decoder",
       "// of the group, and the fields and the size of the dynamic table must match the RFC.",
       "import core::result;", "import std::vec;", "import sys::text;", "import securl::bytes;",
       "import securl::failure;", "import securl::hpack;", "",
       "fn hex(s : *const i8) -> Vec<u8> {", "  let t = lit(s);", "  let mut out = Vec<u8>::new();",
       "  let mut i = 0;", "  while i + 1 < t.len() {",
       "    out.push((hex_value(t.get(i)) * 16 + hex_value(t.get(i + 1))) as u8);", "    i = i + 2;",
       "  }", "  return out;", "}", "",
       "fn check(h : &mut Hpack, data : *const i8, want : *const i8, size : i32) -> void {",
       "  match decode_block(h, &hex(data)) {",
       "    Result<Vec<HeaderField>, Failure>::Ok(fields) => {",
       "      let mut got = Vec<u8>::new();", "      for f in fields.iter() {",
       "        append(&mut got, &f.name);", "        push_lit(&mut got, \": \");",
       "        append(&mut got, &f.value);", "        push_lit(&mut got, \"\\n\");", "      }",
       "      assert(eq_lit(&got, want), \"the decoded fields differ from the RFC\");",
       "      assert(h.dyn_size == size, \"the dynamic table size differs from the RFC\");",
       "    },", "    Result<Vec<HeaderField>, Failure>::Err(_f) => {",
       "      panic(\"an example of the RFC did not decode\");", "    }", "  }", "}", "",
       "fn main() -> i32 {"]
n = 0
for start, end, size in groups:
    sect = section(start, end)
    out.append("  // %s" % start.split("  ")[1])
    out.append("  let mut h%d = new_hpack();" % n)
    out.append("  h%d.max_size = %d;" % (n, size))
    for ex in re.split(r"\n   C\.\d\.\d\.  ", sect)[1:] if False else re.split(r"\nC\.\d\.\d\.  ", sect)[1:]:
        hl = ex[ex.index("Header list to encode:"):ex.index("Hex dump of encoded data:")]
        fields = [l.strip() for l in hl.splitlines()[1:] if l.strip()]
        hd = ex[ex.index("Hex dump of encoded data:"):ex.index("Decoding process:")]
        hexs = "".join("".join(m.group(1).split()) for m in re.finditer(r"^\s+((?:[0-9a-f]{2,4} ?)+)\s*\|", hd, re.M))
        tsize = int(re.search(r"Table size:\s+(\d+)", ex).group(1))
        want = "".join(f + "\\n" for f in fields)
        want = want.replace('"', '\\"')
        out.append('  check(&mut h%d, "%s",\n    "%s", %d);' % (n, hexs, want, tsize))
    n += 1
out += ["  return 0;", "}"]
open(sys.argv[2], "w").write("\n".join(out) + "\n")

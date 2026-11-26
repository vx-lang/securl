#!/usr/bin/env python3
"""Write the HPACK tables of src/securl/hpack.vx from the text of RFC 7541.

    curl -sSo rfc7541.txt https://www.rfc-editor.org/rfc/rfc7541.txt
    python3 tools/gen-hpack-tables.py rfc7541.txt tables.vx

The output is the end of src/securl/hpack.vx, from the line that starts with "// Generated".
It checks that the Huffman code of Appendix B is canonical, which the decoder relies on.
"""
import re, sys
text = open(sys.argv[1]).read()
# Static table.
sect = text[text.index("Appendix A.  Static Table Definition"):text.index("Appendix B.  Huffman Code")]
static = []
for m in re.finditer(r"^\s*\|\s*(\d+)\s*\|\s*(\S+)\s*\|\s*(.*?)\s*\|\s*$", sect, re.M):
    static.append((int(m.group(1)), m.group(2), m.group(3)))
assert [s[0] for s in static] == list(range(1, 62)), len(static)
# Huffman code.
codes = {}
for m in re.finditer(r"\(\s*(\d+)\)\s+\|[01|]+\s+([0-9a-f]+)\s+\[\s*(\d+)\]", text):
    codes[int(m.group(1))] = (int(m.group(2), 16), int(m.group(3)))
m = re.search(r"EOS \(256\)\s+\|[01|]+\s+([0-9a-f]+)\s+\[\s*(\d+)\]", text)
codes[256] = (int(m.group(1), 16), int(m.group(2)))
order = sorted(range(257), key=lambda s: (codes[s][1], s))
# The decoder relies on a canonical code: each code is the previous one + 1, shifted left by the
# change in length.
prev_code, prev_len = None, None
for s in order:
    code, bits = codes[s]
    if prev_code is None:
        assert code == 0
    else:
        assert code == (prev_code + 1) << (bits - prev_len), (s, code, bits)
    prev_code, prev_len = code, bits
out = []
out.append("// Generated from the text of RFC 7541 by a script: Appendix A (the static table) and")
out.append("// Appendix B (the Huffman code, which is canonical).")
out.append("")
out.append("/// The static table: `name value` lines, one for each index from 1 to 61.")
out.append("fn static_table_text() -> Vec<u8> {")
out.append("  let mut t = Vec<u8>::new();")
for i, name, value in static:
    v = value.replace("\\", "\\\\").replace('"', '\\"')
    out.append('  push_lit(&mut t, "%s %s\\n");' % (name, v))
out.append("  return t;")
out.append("}")
out.append("")
out.append("/// The symbols of the Huffman code in canonical order (by code length, then by symbol), each")
out.append("/// as three decimal digits. 256 is EOS.")
out.append("fn huffman_symbols_text() -> Vec<u8> {")
digits = "".join("%03d" % s for s in order)
out.append("  let mut t = Vec<u8>::new();")
for k in range(0, len(digits), 90):
    out.append('  push_lit(&mut t, "%s");' % digits[k:k + 90])
out.append("  return t;")
out.append("}")
out.append("")
out.append("/// For each code length from 1 to 30: the first code of that length, the index of its symbol in")
out.append("/// `huffman_symbols_text`, and how many codes have that length.")
out.append("fn huffman_lengths() -> Vec<i64> {")
out.append("  let mut t = Vec<i64>::new();")
idx = 0
for L in range(1, 31):
    syms = [s for s in order if codes[s][1] == L]
    first = codes[syms[0]][0] if syms else 0
    out.append("  t.push(%di64);" % first)
    out.append("  t.push(%di64);" % idx)
    out.append("  t.push(%di64);" % len(syms))
    idx += len(syms)
out.append("  return t;")
out.append("}")
open(sys.argv[2], "w").write("\n".join(out) + "\n")
print(len(static), "static entries")

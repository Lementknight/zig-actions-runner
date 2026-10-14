#!/usr/bin/env python3
"""Generates src/hpack_tables.zig from RFC 7541 (HPACK) itself: the static table (Appendix A) and the
Huffman code (Appendix B), so the tables come from the specification and nothing else.

    curl -sL https://www.rfc-editor.org/rfc/rfc7541.txt -o rfc7541.txt
    python3 tools/gen_hpack_tables.py rfc7541.txt > src/hpack_tables.zig && zig fmt src/hpack_tables.zig
"""
import re
import sys

text = open(sys.argv[1]).read()

# Appendix B: "    'A' ( 65)  |100001                                  21  [ 6]", the character only for
# printable symbols (symbols 0-255; EOS is 256).
codes = {}
for m in re.finditer(r"^\s*(?:'.' )?\(\s*(\d+)\)\s+\|[01|]+\s+([0-9a-f]+)\s+\[\s*(\d+)\]", text, re.M):
    sym, code, length = int(m.group(1)), int(m.group(2), 16), int(m.group(3))
    codes[sym] = (code, length)
assert sorted(codes) == list(range(256)), "Appendix B: expected symbols 0 to 255"

# Appendix A, and only it (other tables in the RFC look the same): rows such as
# "          | 16    | accept-encoding             | gzip, deflate |" (values may have spaces).
appendix_a = text[text.index("\nAppendix A.  Static Table Definition"):text.index("\nAppendix B.  Huffman Code")]
table = []
for m in re.finditer(r"^\s*\|\s*(\d+)\s*\|\s*(\S+)\s*\|([^|]*)\|\s*$", appendix_a, re.M):
    table.append((int(m.group(1)), m.group(2), m.group(3).strip()))
assert [i for i, _, _ in table] == list(range(1, 62)), "Appendix A: expected entries 1 to 61"

def chunks(items, n):
    for i in range(0, len(items), n):
        yield items[i:i + n]

out = ["//! HPACK tables, generated from RFC 7541 by tools/gen_hpack_tables.py: the Huffman code",
       "//! (Appendix B, symbols 0-255) and the static table (Appendix A).",
       "",
       "pub const huffman_codes = [256]u32{"]
for row in chunks([codes[s][0] for s in range(256)], 8):
    out.append("    " + " ".join(f"0x{c:x}," for c in row))
out += ["};", "", "pub const huffman_lens = [256]u8{"]
for row in chunks([codes[s][1] for s in range(256)], 16):
    out.append("    " + " ".join(f"{l}," for l in row))
out += ["};", "", "/// Static table; index 1 is the first entry.", "pub const static_table = [_][2][]const u8{"]
for _, name, value in table:
    out.append(f'    .{{ "{name}", "{value}" }},')
out.append("};")
print("\n".join(out))

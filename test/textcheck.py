"""Text hygiene for every text file of the repo.

- No broken encoding (UTF-8 read as Latin-1 and saved again: an umlaut turns into A-tilde plus a second
  character, an ellipsis into a-circumflex, euro sign and more) and no replacement character, in any text file.
- Lua comments are plain ASCII: typographic characters (ellipsis, arrows, dashes, curly quotes) break most
  easily there. Strings may hold other characters (UI text, fixture data).

usage: python3 textcheck.py <repo root>
"""
import os, sys

root = sys.argv[1]
TEXT = (".lua", ".py", ".sh", ".md", ".json", ".yml", ".yaml", ".css", ".txt")
# A-tilde, a-circumflex + euro sign, A-circumflex: lead bytes of UTF-8 read as Latin-1 / cp1252
MOJIBAKE = (chr(0xC3), chr(0xE2) + chr(0x20AC), chr(0xC2), chr(0xFFFD))
errors = []


def comment_of(line):
    # the "--" comment of a line, outside of strings; good enough for our code (no long strings)
    in_str = None
    i = 0
    while i < len(line):
        c = line[i]
        if in_str:
            if c == "\\":
                i += 1
            elif c == in_str:
                in_str = None
        elif c in "\"'":
            in_str = c
        elif line.startswith("--", i):
            return line[i:]
        i += 1
    return ""


for dirpath, dirs, files in os.walk(root):
    dirs[:] = [d for d in dirs if d != ".git"]
    for f in files:
        if not f.endswith(TEXT):
            continue
        path = os.path.join(dirpath, f)
        rel = os.path.relpath(path, root)
        try:
            text = open(path, encoding="utf-8").read()
        except UnicodeDecodeError as e:
            errors.append("%s: not valid UTF-8 (%s)" % (rel, e))
            continue
        for n, line in enumerate(text.split("\n"), 1):
            for bad in MOJIBAKE:
                if bad in line:
                    errors.append("%s:%d: broken encoding %r" % (rel, n, bad))
            if f.endswith(".lua"):
                comment = comment_of(line)
                odd = sorted({ch for ch in comment if ord(ch) > 127})
                if odd:
                    errors.append("%s:%d: non-ASCII in a comment: %s" % (rel, n, " ".join(odd)))

for e in errors:
    print("TEXT: " + e)
print("text check: %d problems" % len(errors))
sys.exit(1 if errors else 0)

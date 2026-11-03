import base64, re, sys
import xml.etree.ElementTree as ET

path = sys.argv[1] if len(sys.argv) > 1 else "arraybackup.plg"
raw = open(path, "rb").read()
print("size:", len(raw), "| BOM:", raw[:3] == b"\xef\xbb\xbf", "| CRLF:", b"\r\n" in raw)

try:
    root = ET.fromstring(raw.decode("utf-8"))
    print("XML: OK, root =", root.tag)
except Exception as e:
    print("XML ERROR:", e)
    sys.exit(1)

ok = True
for m in re.finditer(r'<file name="([^"]+)" mode="([^"]*)" type="base64">\s*(.*?)\s*</file>', raw.decode("utf-8"), re.S):
    name, mode, b64 = m.groups()
    if "\r" in b64 or "\n" in b64.replace("\n", ""):
        pass
    if any(c.isspace() for c in b64):
        print(name, "-> base64 contains whitespace (lenient parsers usually tolerate)")
    try:
        data = base64.b64decode(b64)
        print(f"  {name}  mode={mode}  base64 OK, {len(data)} bytes, starts: {data[:20]!r}")
    except Exception as e:
        ok = False
        print(name, "-> BASE64 ERROR:", e)

for el in root.iter("cmd"):
    if "<" in (el.text or "").replace("\n", " ") and "<<" in (el.text or ""):
        print("cmd block still has heredoc-ish content?")

print("RESULT:", "PASS" if ok else "FAIL")

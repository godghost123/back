#!/usr/bin/env python3
"""Validate arraybackup.plg: XML well-formedness, base64 payloads, SHA256
blocks, and a single <PLUGIN> root. Exits non-zero on any real error so it can
serve as the build gate (build.sh runs it after generating the PLG).

Fix vs. the old version: the FILE regex used lowercase <file name=...> while
build.sh emits <FILE Name=... Type="base64" Mode=...>, so the base64 payload
check NEVER ran; and it iterated <cmd> *elements* although the manager uses
<FILE Run=...> with <INLINE>. Both are corrected here, and every discovered
problem now affects the exit code.
"""
import base64
import hashlib
import re
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1] if len(sys.argv) > 1 else "arraybackup.plg"
raw = open(path, "rb").read()
print(f"file: {path} | size: {len(raw)} | BOM: {raw[:3] == b'\xef\xbb\xbf'} | CRLF: {b'\r\n' in raw}")

errors = []
warnings = []

if raw[:3] == b"\xef\xbb\xbf":
    warnings.append("UTF-8 BOM present (emhttp's XML parser may choke)")
if b"\r\n" in raw:
    errors.append("CRLF bytes inside the PLG (breaks base64 payloads on install)")

# --- XML structure -----------------------------------------------------------
try:
    root = ET.fromstring(raw.decode("utf-8"))
    print(f"XML: OK, root = <{root.tag}> name={root.get('name')!r} version={root.get('version')!r}")
    if root.tag != "PLUGIN":
        errors.append(f"root element is <{root.tag}>, expected <PLUGIN>")
except Exception as e:
    print("XML ERROR:", e)
    sys.exit(1)

if len(re.findall(rb"<PLUGIN[\s>]", raw)) != 1:
    errors.append("PLG must contain exactly one <PLUGIN ...> element")

if root.tag == "PLUGIN":
    for attr in ("name", "version", "pluginURL"):
        if not root.get(attr):
            errors.append(f"<PLUGIN> missing required attribute {attr!r}")

# --- FILE payloads -----------------------------------------------------------
file_els = root.findall("FILE")
if not file_els:
    errors.append("no <FILE> elements found")

b64_count = run_count = 0
for el in file_els:
    name = el.get("Name") or ""
    mode = el.get("Mode") or ""
    ftype = (el.get("Type") or "").lower()
    run = el.get("Run")
    inline = el.find("INLINE")
    body = (inline.text or "") if inline is not None else ""

    if run:
        run_count += 1
        # Manager semantics:
        #  - Run + Type=base64 + Name  -> writes the named file, then executes it
        #    (that's how install.sh runs at install/update/boot)
        #  - Run + empty Name + INLINE -> executes the INLINE text itself
        #  - Run + Name + non-base64 INLINE -> the manager would run "$Run $Name"
        #    instead of the inline script - almost certainly a bug.
        if name and ftype != "base64":
            warnings.append(f'<FILE Name="{name}" Run="{run}">: without Type="base64" the manager runs "$Run $Name", not the INLINE script')
        if run and ftype != "base64" and not body.strip():
            errors.append(f"<FILE Run={run!r}> has empty INLINE")
        if ftype == "base64":
            b64_count += 1
            compact = "".join(body.split())
            try:
                data = base64.b64decode(compact, validate=True)
            except Exception as e:
                errors.append(f"{name}: BASE64 ERROR: {e}")
                data = b""
            if data:
                sha_el = el.find("SHA256")
                if sha_el is not None and (sha_el.text or "").strip():
                    want = sha_el.text.strip().lower()
                    got = hashlib.sha256(data).hexdigest()
                    if want != got:
                        errors.append(f"{name}: SHA256 mismatch (PLG says {want}, payload hashes to {got})")
                print(f"  FILE(Run,base64) {name}  method={el.get('Method') or 'install'}  {len(data)} bytes")
            continue
        print(f"  FILE(Run) {name or '-'}  method={el.get('Method') or 'install'}  type={ftype or 'inline'}  {len(body)} bytes")
        continue

    if ftype == "base64":
        b64_count += 1
        compact = "".join(body.split())
        if not compact:
            errors.append(f"{name}: empty base64 INLINE")
            continue
        try:
            data = base64.b64decode(compact, validate=True)
        except Exception as e:
            errors.append(f"{name}: BASE64 ERROR: {e}")
            continue
        sha_el = el.find("SHA256")
        if sha_el is None or not (sha_el.text or "").strip():
            warnings.append(f"{name}: no SHA256 block - manager may skip re-writing this file on update")
        else:
            want = sha_el.text.strip().lower()
            got = hashlib.sha256(data).hexdigest()
            if want != got:
                errors.append(f"{name}: SHA256 mismatch (PLG says {want}, payload hashes to {got})")
        if len(data) < 16:
            warnings.append(f"{name}: suspiciously small payload ({len(data)} bytes)")
        print(f"  FILE {name}  mode={mode}  base64 OK {len(data)} bytes  head={data[:12]!r}")
    else:
        print(f"  FILE {name}  mode={mode}  type={ftype or 'plain'}  {len(body)} bytes inline")

print(f"stats: {len(file_els)} FILE elements, {b64_count} base64 payloads, {run_count} Run blocks")

for w in warnings:
    print("WARNING:", w)
for e in errors:
    print("ERROR:", e)

if errors:
    print("RESULT: FAIL")
    sys.exit(1)
print("RESULT: PASS")

#!/usr/bin/env python3
"""Builds the website's free prep pack downloads from prep-kits/:
site/prep-kits/<slug>.snazzyprep for each role, and all-roles.snazzyprep.

A .snazzyprep file is a plain zip of <slug>/prep-kit.json (no passcode, no
encryption), the same format Snazzy Pro's Share Prep Pack makes.

    python3 Scripts/prep-packs.py
"""
import json, pathlib, zipfile

root = pathlib.Path(__file__).resolve().parent.parent
kits = sorted(p.parent for p in (root / "prep-kits").glob("*/prep-kit.json"))
out = root / "site" / "prep-kits"
out.mkdir(parents=True, exist_ok=True)

def pack(path, folders):
    roles = [json.loads((f / "prep-kit.json").read_text())["role"] for f in folders]
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for f in folders:
            info = zipfile.ZipInfo(f"{f.name}/prep-kit.json", date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, (f / "prep-kit.json").read_bytes())
        info = zipfile.ZipInfo("README.txt", date_time=(1980, 1, 1, 0, 0, 0))
        z.writestr(info, f"Snazzy Pro interview prep pack: {', '.join(roles)}.\n\n"
                   "Open this file with Snazzy Pro (https://snazzy.pro) to study the topics, do the\n"
                   "hands-on exercises and practise the interview with your own AI model. Free.\n")
    print(f"{path.relative_to(root)}: {path.stat().st_size} bytes")

for f in kits:
    pack(out / f"{f.name}.snazzyprep", [f])
pack(out / "all-roles.snazzyprep", kits)

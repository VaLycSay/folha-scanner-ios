import hashlib
import json
import os
from pathlib import Path
import runpy
import zipfile

ROOT = Path(os.environ["PRIVATE_WORK"]).resolve()
# Preserve the existing private packager and original binary integrity gates.
runpy.run_path(str(Path(__file__).with_name("rebrand.py")), run_name="__main__")
out = ROOT / "delivery"
manifest_path = out / "manifesto.json"
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
old_name = manifest["output"]
new_name = "Scanner-REA-Plus-5.26.12-salvar-direto-v3.ipa"
assert old_name == "Scanner-REA-Plus-5.26.12-lote-auto-v2.ipa"
target = out / new_name
assert not target.exists()
(out / old_name).rename(target)
manifest["output"] = new_name
manifest["flow_revision"] = "v3: native batch completion, optional editing, no mandatory extra review"
manifest["capture_adjustments"]["flow_adapter"] = "own module: two hooks; normal batch default and native save path; no preview-finish hook"
manifest["flow_test_scope"] = "macOS test doubles; not a physical iPhone test"
with target.open("rb") as stream:
    assert hashlib.file_digest(stream, "sha256").hexdigest() == manifest["output_sha256"]
manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
(out / "capture-adjustments.json").write_text(json.dumps(manifest["capture_adjustments"], indent=2), encoding="utf-8")
(out / (new_name + ".sha256")).write_text(manifest["output_sha256"] + "  " + new_name + "\n", encoding="ascii")
(out / (old_name + ".sha256")).unlink()
(out / "LEIA-ME.txt").write_text(Path(__file__).with_name("LEIA-ME-v3.txt").read_text(encoding="utf-8"), encoding="utf-8")
with zipfile.ZipFile(ROOT / "delivery.zip", "w", zipfile.ZIP_DEFLATED, compresslevel=1) as bundle:
    for item in sorted(out.iterdir()):
        bundle.write(item, item.name)
print("Private V3 package prepared. Native detector and optional editing retained.")

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import stat
import struct
import subprocess
import zipfile

ROOT = Path(os.environ["PRIVATE_WORK"]).resolve()
SOURCE = ROOT / "source.ipa"
EXPECTED = "ab77ea7f69f13340d5efb30f948e4aa2d28ca1ad950425aa06b30635bcb74e7e"
BRAND = "Scanner REA"
APP_PREFIX = "Payload/CamScanner.app/"
IPA_NAME = "Scanner-REA-Plus-5.26.12-experimental.ipa"
OUT = ROOT / "delivery"
OUT.mkdir()
EXTRACT = ROOT / "reference"
EXTRACT.mkdir()

def digest(data):
    return hashlib.sha256(data).hexdigest()

def file_hash(path):
    with open(path, "rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()

assert file_hash(SOURCE) == EXPECTED, "Source identity mismatch"

def safe_path(name):
    p = PurePosixPath(name)
    if p.is_absolute() or ".." in p.parts or "\\" in name:
        raise ValueError("Unsafe ZIP path")
    target = EXTRACT.joinpath(*p.parts)
    if not target.resolve().is_relative_to(EXTRACT):
        raise ValueError("ZIP path escapes private workspace")
    return target

def run_private(name, args):
    process = subprocess.run(args, capture_output=True, text=True, errors="replace", timeout=180)
    (OUT / (name + ".log")).write_text(process.stdout + "\n" + process.stderr, encoding="utf-8")
    return {"exit_code": process.returncode, "report": name + ".log"}

originals = {}
binary_paths = []
with zipfile.ZipFile(SOURCE) as z:
    for entry in z.infolist():
        if not entry.filename.startswith("Payload/"):
            continue
        target = safe_path(entry.filename)
        if stat.S_ISLNK(entry.external_attr >> 16):
            raise ValueError("Unexpected symlink requires review")
        if entry.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            continue
        data = z.read(entry)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        mode = (entry.external_attr >> 16) & 0o777
        if mode:
            target.chmod(mode)
        originals[entry.filename] = digest(data)
        if entry.filename.endswith("/Info.plist"):
            info = plistlib.loads(data)
            executable = info.get("CFBundleExecutable")
            if executable:
                binary_paths.append(str(PurePosixPath(entry.filename).parent / executable))

app = EXTRACT / "Payload/CamScanner.app"
reports = {
    "codesign_metadata": run_private("original-codesign-metadata", ["codesign", "-d", "--verbose=4", str(app)]),
    "codesign_verification": run_private("original-codesign-verification", ["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)]),
    "rea_main_signature": run_private("rea-main-signature", ["node", os.environ["REA_CLI"], "inspect-signature", str(app / "CamScanner"), "--format", "json"]),
    "rea_framework_signature": run_private("rea-framework-signature", ["node", os.environ["REA_CLI"], "inspect-signature", str(app / "Frameworks/ICELib.framework/ICELib"), "--format", "json"]),
}
binary_paths = sorted({p for p in binary_paths if p in originals})
assert len(binary_paths) == 6, "Unexpected binary inventory"
assert originals[APP_PREFIX + "CamScanner"] == "df2346e1e6fa1fa6c96970f53493f1488d9a1631d471e0baec6cea6ebf062528"
assert originals[APP_PREFIX + "Frameworks/ICELib.framework/ICELib"] == "feb175880e9785a366f238669fed713bd95311c4cf8ca3d935bc66e6a9ff8d9c"

changed = {}
removed = []
added = []

def write_changed(path, data, reason):
    rel = path.relative_to(EXTRACT).as_posix()
    old = path.read_bytes()
    if old == data:
        return
    path.write_bytes(data)
    changed[rel] = {"reason": reason, "before": digest(old), "after": digest(data)}

info_path = app / "Info.plist"
info = plistlib.loads(info_path.read_bytes())
info["CFBundleDisplayName"] = BRAND
info["CFBundleName"] = BRAND
icon_spec = info.setdefault("CFBundleIcons", {})
primary = icon_spec.setdefault("CFBundlePrimaryIcon", {})
primary.pop("CFBundleIconName", None)
primary["CFBundleIconFiles"] = ["ScannerREA60x60"]
info["CFBundleIconFiles"] = ["icon.png", "icon@2x.png", "icon_retina.png"]
write_changed(info_path, plistlib.dumps(info, fmt=plistlib.FMT_BINARY, sort_keys=False), "display name and icon metadata only")

# Keep alternate icon keys and all purchase-dependent behavior intact.
# Only images referenced as application icons are replaced.
icon_stems = {"icon", "icon_retina", "AppIconPlus60x60"}
for settings in icon_spec.get("CFBundleAlternateIcons", {}).values():
    icon_stems.update(settings.get("CFBundleIconFiles", []))

for path in app.glob("*.png"):
    stem = path.stem.split("@")[0].split("~")[0]
    if stem not in icon_stems:
        continue
    old = path.read_bytes()
    if old[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("Unexpected icon format")
    offset = 8
    dimensions = None
    while offset + 12 <= len(old):
        length = struct.unpack(">I", old[offset:offset + 4])[0]
        kind = old[offset + 4:offset + 8]
        if offset + 12 + length > len(old):
            raise ValueError("Truncated PNG chunk")
        if kind == b"IHDR":
            if length != 13:
                raise ValueError("Invalid PNG IHDR length")
            dimensions = struct.unpack(">II", old[offset + 8:offset + 16])
            break
        offset += length + 12
    if dimensions is None:
        raise ValueError("PNG IHDR not found")
    width, height = dimensions
    if width != height:
        raise ValueError("Unexpected non-square app icon")
    brand = ROOT / "brand" / (str(width) + ".png")
    if not brand.exists():
        raise ValueError("Unexpected icon size: " + str(width))
    write_changed(path, brand.read_bytes(), "application icon only")

for filename, size in [("ScannerREA60x60@2x.png", 120), ("ScannerREA60x60@3x.png", 180)]:
    target = app / filename
    assert not target.exists()
    target.write_bytes((ROOT / "brand" / (str(size) + ".png")).read_bytes())
    added.append(target.relative_to(EXTRACT).as_posix())

localized_names = 0
exact_ui_names = 0
for path in app.glob("*.lproj/*.strings"):
    if path.name not in ("InfoPlist.strings", "Localizable.strings"):
        continue
    raw = path.read_bytes()
    try:
        values = plistlib.loads(raw)
    except plistlib.InvalidFileException:
        continue
    if not isinstance(values, dict):
        continue
    modified = False
    if path.name == "InfoPlist.strings":
        for key in ("CFBundleDisplayName", "CFBundleName"):
            if key in values:
                values[key] = BRAND
                modified = True
                localized_names += 1
    else:
        for key, value in values.items():
            if value in ("CamScanner", "CamScanner+", "CamScanner +", "camscanner"):
                values[key] = BRAND
                modified = True
                exact_ui_names += 1
    if modified:
        write_changed(path, plistlib.dumps(values, fmt=plistlib.FMT_BINARY, sort_keys=False), "localized standalone product name only")

# Resource seals and signing profiles are packaging metadata, not licenses.
# Executable signature bytes, receipts, purchase logic, IDs and endpoints remain unchanged.
for name in list(originals):
    p = PurePosixPath(name)
    if "_CodeSignature" in p.parts or p.name == "embedded.mobileprovision":
        (EXTRACT / name).unlink()
        removed.append(name)

binary_receipt = []
for name in binary_paths:
    now = file_hash(EXTRACT / name)
    assert now == originals[name], "Executable changed: " + name
    binary_receipt.append({"path": name, "sha256": now, "byte_identical": True})

for name, before in originals.items():
    if name in removed or name in changed:
        continue
    assert file_hash(EXTRACT / name) == before, "Unexpected resource change: " + name

ipa = OUT / IPA_NAME
with zipfile.ZipFile(ipa, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as output:
    for path in sorted(EXTRACT.rglob("*")):
        if path.is_file():
            output.write(path, path.relative_to(EXTRACT).as_posix())

# Reopen the produced package and prove member-level preservation.
with zipfile.ZipFile(ipa) as result:
    expected_members = (set(originals) - set(removed)) | set(added)
    assert set(result.namelist()) == expected_members, "Final member inventory mismatch"
    for name in expected_members:
        expected_hash = changed[name]["after"] if name in changed else (
            file_hash(EXTRACT / name) if name in added else originals[name])
        assert digest(result.read(name)) == expected_hash, "Packaged content mismatch: " + name
    final_info = plistlib.loads(result.read(APP_PREFIX + "Info.plist"))
    assert final_info["CFBundleIdentifier"] == "com.intsig.CamScanner"
    assert final_info["CFBundleDisplayName"] == BRAND

receipt = {
    "status": "packaged_for_private_device_test",
    "source_sha256": EXPECTED,
    "output": IPA_NAME, "output_sha256": file_hash(ipa),
    "brand": BRAND, "base_version": "5.26.12",
    "bundle_identifier_preserved": "com.intsig.CamScanner",
    "binary_preservation": binary_receipt,
    "localized_display_names_changed": localized_names,
    "standalone_ui_brand_values_changed": exact_ui_names,
    "changed_resources": changed, "removed_signing_metadata": removed, "added_icons": added,
    "all_other_payload_files_byte_identical": True,
    "static_inspection": reports,
    "encrypted_extensions_preserved": 4,
    "license_and_purchase_logic_modified": False,
    "authenticity_proven": False, "device_installation_tested": False, "camera_tested": False,
    "limitations": [
        "Community source authenticity has not been established.",
        "All four encrypted extensions were preserved, not decrypted or removed.",
        "A complete new device signature is required. Installation may fail.",
        "The original bundle identifier is preserved; do not overwrite an installed original app with valuable data.",
        "Only resource-level branding changed; compiled, remote and legal vendor branding may remain.",
        "Vendor account, paid services and cloud dependencies remain unchanged."
    ]
}
(OUT / "manifesto.json").write_text(json.dumps(receipt, indent=2, ensure_ascii=True), encoding="utf-8")
(OUT / (IPA_NAME + ".sha256")).write_text(receipt["output_sha256"] + "  " + IPA_NAME + "\n", encoding="ascii")
(OUT / "LEIA-ME.txt").write_text(
    "SCANNER REA PLUS - EXPERIMENTO PRIVADO\n\n"
    "Base: CamScanner+ 5.26.12. Nao e a recriacao independente 0.5.0.\n"
    "Nome/icone e rotulos de marca foram alterados em recursos; os seis executaveis/bibliotecas permanecem byte a byte identicos.\n"
    "O detector e os fluxos NAO foram reimplementados. Isso nao comprova funcionamento depois de reassinar.\n\n"
    "ANTES DE INSTALAR\n"
    "- Fonte comunitaria: autenticidade e seguranca nao comprovadas. Use ambiente de teste e documentos ficticios, sem credenciais reais.\n"
    "- Necessita nova assinatura e provisionamento. Nao foi testado no seu iPhone/iOS.\n"
    "- Bundle ID original preservado. NAO instale por cima do CamScanner+ que contenha documentos importantes.\n"
    "- Quatro extensoes continuam criptografadas e podem impedir instalacao/uso. Nao foram removidas nem desbloqueadas.\n"
    "- Assinador que mudar IDs ou remover extensoes introduzira alteracoes alem deste pacote; informe quais opcoes usou.\n\n"
    "TESTE MANUAL\n"
    "1. Assinar/instalar sem substituir uma instalacao de uso real; anotar erro completo se houver.\n"
    "2. Conferir nome e icone, abrir camera e reconhecer uma folha com texto.\n"
    "3. Testar folha em movimento, fundo claro/escuro e pouca luz.\n"
    "4. Capturar varias paginas, recortar, filtrar, salvar, fechar e reabrir.\n"
    "5. Exportar PDF/JPEG e comparar a ordem e o conteudo.\n"
    "6. Nao inserir conta pessoal para testar nuvem. Premium permanece sujeito a licenca original.\n\n"
    "LIMITES\n"
    "Marcas compiladas, telas legais e servicos do fornecedor podem continuar exibindo CamScanner.\n"
    "Nenhuma assinatura Premium foi simulada e nenhum recurso pago foi desbloqueado.\n"
    "O original nao foi incluido na entrega. Logs e manifesto detalham a inspecao estatica.\n",
    encoding="utf-8")
with zipfile.ZipFile(ROOT / "delivery.zip", "w", zipfile.ZIP_DEFLATED, compresslevel=1) as package:
    for path in sorted(OUT.iterdir()):
        package.write(path, path.name)
print("Private packaging complete; six code components preserved.")

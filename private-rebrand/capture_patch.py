import hashlib
import json
import struct
from pathlib import Path

MAIN_HASH = "df2346e1e6fa1fa6c96970f53493f1488d9a1631d471e0baec6cea6ebf062528"
LIBRARY = "@executable_path/Frameworks/ScannerREAFlow.dylib"
TIMER_VA = 0x100228720
PROTECTED = [
    ("frame_detector_entry", 0x10022784c, 0x100227d48),
    ("rectangle_geometry_and_stability", 0x100227d48, 0x100228670),
    ("vertex_and_area_criteria", 0x100228848, 0x100228ee0),
    ("capture_frame_callback", 0x100872b78, 0x100872f18),
    ("batch_save_and_rearm", 0x100873078, 0x100873754),
    ("camera_photo_routing", 0x10086fc48, 0x100871868),
]
def digest(value):
    return hashlib.sha256(value).hexdigest()

def macho(data):
    assert struct.unpack_from("<I", data)[0] == 0xfeedfacf, "Expected thin Mach-O 64"
    assert struct.unpack_from("<I", data, 4)[0] == 0x100000c, "Expected arm64"
    commands, size = struct.unpack_from("<II", data, 16)
    segments, sections = [], []
    p = 32
    for _ in range(commands):
        cmd, length = struct.unpack_from("<II", data, p)
        assert length >= 8 and p + length <= 32 + size
        if cmd == 0x19:
            vm, virtual_size, file_offset, file_size = struct.unpack_from("<QQQQ", data, p + 24)
            segments.append((vm, file_offset, file_size))
            for j in range(struct.unpack_from("<I", data, p + 64)[0]):
                q = p + 72 + 80 * j
                name = data[q:q + 16].split(b"\0")[0].decode("ascii")
                address, section_size = struct.unpack_from("<QQ", data, q + 32)
                offset = struct.unpack_from("<I", data, q + 48)[0]
                if offset:
                    sections.append((name, address, section_size, offset))
        p += length
    assert p == 32 + size
    return commands, size, segments, sections

def offset_at(segments, address):
    for vm, offset, size in segments:
        if vm <= address < vm + size:
            return offset + address - vm
    raise ValueError("Unmapped address")

def patch_capture(data, output_dir):
    assert digest(data) == MAIN_HASH, "Unsupported binary snapshot"
    commands, size, segments, sections = macho(data)
    # Generate both instructions independently with Apple's assembler.
    original_object = Path(output_dir) / "timer-encoding.o"
    _, _, _, object_sections = macho(original_object.read_bytes())
    text_section = next(s for s in object_sections if s[0] == "__text")
    text = original_object.read_bytes()[text_section[3]:text_section[3] + text_section[2]]
    assert len(text) == 8, "Expected exactly two independently assembled instructions"
    old_timer, new_timer = text[:4], text[4:]
    assert old_timer != new_timer
    timer = offset_at(segments, TIMER_VA)
    assert data[timer:timer + 4] == old_timer, "Timer instruction mismatch"
    name = LIBRARY.encode("ascii") + b"\0"
    command_size = (24 + len(name) + 7) & ~7
    command = struct.pack("<IIIIII", 0xc, command_size, 24, 0, 0x10000, 0x10000)
    command += name + bytes(command_size - 24 - len(name))
    start = 32 + size
    first_section = min(s[3] for s in sections)
    assert start + command_size <= first_section, "Insufficient header padding"
    assert not any(data[start:start + command_size]), "Header padding is not empty"
    assert LIBRARY.encode("ascii") not in data[:start], "Already adapted"
    result = bytearray(data)
    struct.pack_into("<II", result, 16, commands + 1, size + command_size)
    result[start:start + command_size] = command
    result[timer:timer + 4] = new_timer
    # Exact inverse proves all existing code and data outside this allowlist unchanged.
    restored = bytearray(result)
    restored[16:24] = data[16:24]
    restored[start:start + command_size] = data[start:start + command_size]
    restored[timer:timer + 4] = data[timer:timer + 4]
    assert restored == data, "Unexpected alteration outside allowlist"
    guards = []
    for name, begin, end in PROTECTED:
        lo, hi = offset_at(segments, begin), offset_at(segments, end - 1) + 1
        assert data[lo:hi] == result[lo:hi], name
        guards.append({"region": name, "sha256": digest(data[lo:hi]), "byte_identical": True})
    n, new_size, _, _ = macho(result)
    assert n == commands + 1 and new_size == size + command_size
    receipt = {
        "original_sha256": digest(data), "modified_sha256": digest(result),
        "original_code_changes": [{"virtual_address": hex(TIMER_VA), "size": 4,
            "purpose": "post-valid-border dwell time 1.5s -> 1.0s; no geometry thresholds changed"}],
        "loader_header": {"offset": start, "size": command_size, "library": LIBRARY},
        "all_other_original_bytes_identical": True,
        "protected_regions": guards,
        "flow_adapter": "own Objective-C module; normal batch default and final-review lifecycle only",
        "word_conversion": "existing traced path uploads PDF and downloads Word from vendor service; not unlocked",
        "physical_camera_tested": False,
    }
    return bytes(result), receipt

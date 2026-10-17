"""Read-only audit of Godot 4.7 embedded, unencrypted PCK v2/v3/v4.

Format reference: Godot 4.7.1 core/io/file_access_pack.{h,cpp}.
https://github.com/godotengine/godot/blob/4.7.1-stable/core/io/file_access_pack.cpp
"""
from pathlib import Path
import argparse
import hashlib
import json
import struct

def audit(executable, expected_native_hash):
    raw = executable.read_bytes()
    assert raw[-4:] == b'GDPC', 'Embedded PCK footer missing'
    length = struct.unpack_from('<Q', raw, len(raw) - 12)[0]
    start = len(raw) - 12 - length
    assert raw[start:start + 4] == b'GDPC'
    version, major, minor, patch, flags = struct.unpack_from('<5I', raw, start + 4)
    assert version in (2, 3, 4) and not flags & 5, 'Unsupported encrypted/sparse pack'
    base = struct.unpack_from('<Q', raw, start + 24)[0]
    if version >= 3 or flags & 2: base += start
    cursor = start + 96
    if version >= 3: cursor = start + struct.unpack_from('<Q', raw, start + 32)[0]
    count = struct.unpack_from('<I', raw, cursor)[0]
    cursor += 4
    entries = []
    payloads = {}
    for _ in range(count):
        size = struct.unpack_from('<I', raw, cursor)[0]
        cursor += 4
        name = raw[cursor:cursor + size].rstrip(b'\0').decode('utf8').removeprefix('res://')
        cursor += size
        offset, byte_count = struct.unpack_from('<QQ', raw, cursor)
        cursor += 16
        md5 = raw[cursor:cursor + 16]
        cursor += 16
        file_flags = struct.unpack_from('<I', raw, cursor)[0]
        cursor += 4
        assert file_flags == 0, (name, file_flags)
        content = raw[base + offset:base + offset + byte_count]
        assert len(content) == byte_count and hashlib.md5(content).digest() == md5, name
        assert '..' not in Path(name).parts and not Path(name).is_absolute(), name
        assert not any(name.startswith(p) for p in ['gameplay/', 'validation/', 'temp/', 'addons/godot_mcp', 'Splash_1/']), name
        entries.append({'path': name, 'bytes': byte_count, 'md5_verified': True})
        if byte_count < 1000000: payloads[name] = content
    names = {row['path'] for row in entries}
    for scene in ['addons/ocean/ocean.tscn', 'addons/jet_ski/jet_ski_01/jet_ski_01.tscn', 'addons/jet_ski/examples/ocean_jet_ski_demo.tscn']:
        assert scene in names or scene + '.remap' in names, scene
    for frame in range(1, 9):
        image = f'addons/jet_ski/common/visual/bow_spray/sequences/Splash_1/{frame:03}.png'
        assert image in names or image + '.import' in names, image
    for tail in ['ocean_underwater_medium.glsl.source', 'ocean_underwater_medium_bubbles_procedural.inc', 'ocean_underwater_medium_bubbles_optimized.inc']:
        assert 'addons/ocean/underwater/shaders/' + tail in names, tail
    descriptor = 'addons/ocean/physics/native/ocean_query/ocean_query_native.gdextension'
    assert descriptor in names and '.godot/extension_list.cfg' in names
    assert descriptor.encode() in payloads['.godot/extension_list.cfg']
    project = payloads['project.binary']
    assert b'addons/jet_ski/examples/ocean_jet_ski_demo.tscn' in project
    assert b'MCPRuntimeServer' not in project and b'gameplay/' not in project and b'validation/' not in project
    native = 'ocean_query_native.windows.template_release.x86_64.dll' if executable.suffix == '.exe' else 'ocean_query_native.linux.template_release.x86_64.so'
    library = executable.parent / native
    assert library.is_file() and hashlib.sha256(library.read_bytes()).hexdigest() == expected_native_hash
    config = payloads[descriptor].decode('utf8')
    assert native in config
    prefixes = (b'C:/Users/', b'C:\\Users\\', b'/mnt/c/Users/', b'/opt/e1/clean_project')
    functional_path_hits = []
    for name, content in payloads.items():
        if any(prefix in content for prefix in prefixes): functional_path_hits.append(name)
    assert not functional_path_hits, functional_path_hits
    return {'passed': True, 'executable': str(executable), 'bytes': executable.stat().st_size,
            'sha256': hashlib.sha256(raw).hexdigest(), 'pck_version': version,
            'engine': [major, minor, patch], 'files': count, 'all_entry_md5_verified': True,
            'native': native, 'native_sha256': expected_native_hash,
            'descriptor': config, 'no_development_resource_paths': True,
            'no_absolute_development_paths_in_small_packed_files': True,
            'shader_cache_bytes': sum(row['bytes'] for row in entries if row['path'].startswith('.godot/shader_cache/')),
            'entries': entries}

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('executable', type=Path)
    parser.add_argument('--native-sha256', required=True)
    parser.add_argument('--result', required=True, type=Path)
    options = parser.parse_args()
    report = audit(options.executable, options.native_sha256)
    options.result.write_text(json.dumps(report, indent=2), encoding='utf8')
    print(json.dumps({k:v for k,v in report.items() if k not in ['entries', 'descriptor']}))

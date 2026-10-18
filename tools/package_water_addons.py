"""Build standalone Ocean/Jet Ski source archives and a clean import fixture.

Run from the repository root. Development scenes, raw sprite sequences,
captures, MCP, native build products and the Godot cache are never packaged.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SKIP_DIRS = {'.godot', '.git', '__pycache__', 'godot-cpp', 'build', 'perf1'}
SKIP_SUFFIXES = {'.obj', '.lib', '.exp', '.pdb', '.tmp', '.pyc'}
TEXT_SUFFIXES = {'.gd', '.tscn', '.tres', '.gdshader', '.gdshaderinc', '.glsl', '.inc', '.source'}
NATIVE_LIBRARIES = {
    'ocean_query_native.windows.template_release.x86_64.dll',
    'ocean_query_native.linux.template_release.x86_64.so',
}


def files(addon):
    for path in sorted((ROOT / 'addons' / addon).rglob('*')):
        if not path.is_file():
            continue
        rel = path.relative_to(ROOT)
        if any(part in SKIP_DIRS for part in rel.parts) or path.name.startswith('~'):
            continue
        if path.suffix.lower() in SKIP_SUFFIXES or path.name == '.sconsign.dblite':
            continue
        if 'bin' in rel.parts and path.name not in NATIVE_LIBRARIES:
            continue
        # Keep import settings and stable UIDs. Godot regenerates the missing
        # cached payloads inside the destination project's own .godot directory.
        yield path, rel


def build(destination):
    destination = destination.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    project = destination / 'TestAddons'
    ocean_only = destination / 'OceanOnly'
    # Unique, new output roots prevent stale files from hiding missing dependencies.
    if project.exists() or ocean_only.exists():
        raise SystemExit('Choose a new output directory; existing test projects are preserved.')
    records = []
    for addon in ['ocean', 'jet_ski']:
        archive = destination / f'{addon}_source.zip'
        with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as packed:
            for path, relative in files(addon):
                data = path.read_bytes()
                packed.writestr(relative.as_posix(), data)
                target = project / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
                if addon == 'ocean':
                    target = ocean_only / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(data)
                records.append({'path': relative.as_posix(), 'bytes': len(data),
                                'sha256': hashlib.sha256(data).hexdigest()})
    # Audit resource paths after materializing both addons. Wildcard shader paths
    # and dynamic folder prefixes are checked at runtime by the smoke test.
    missing = []
    development = []
    for row in records:
        path = project / row['path']
        if path.suffix not in TEXT_SUFFIXES:
            continue
        for resource in re.findall(r'res://[^\s"\'<>]+', path.read_text(encoding='utf-8')):
            if resource.startswith(('res://temp/', 'res://validation/', 'res://gameplay/', 'res://Splash_')):
                development.append((row['path'], resource))
            if '%' not in resource and not resource.endswith('/') and not (project / resource[6:]).exists():
                missing.append((row['path'], resource))
    if missing or development:
        raise SystemExit(json.dumps({'missing': missing, 'development_dependencies': development}, indent=2))
    config = (ROOT / 'addons/jet_ski/examples/project.godot.example').read_text(encoding='utf-8')
    (project / 'project.godot').write_text(config, encoding='utf-8')
    ocean_config = config.replace('res://addons/jet_ski/examples/ocean_jet_ski_demo.tscn', 'res://addons/ocean/ocean.tscn')
    ocean_config = ocean_config.replace('enabled=PackedStringArray("res://addons/jet_ski/plugin.cfg")',
                                        'enabled=PackedStringArray()')
    (ocean_only / 'project.godot').write_text(ocean_config, encoding='utf-8')
    manifest = {'files': records, 'development_dependencies': [], 'missing_dependencies': [],
                'test_project': str(project), 'ocean_only_project': str(ocean_only),
                'export_include_filter': '*.glsl,*.inc,*.source'}
    (destination / 'manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    print(json.dumps({'files': len(records), 'destination': str(destination),
                      'source_bytes': sum(row['bytes'] for row in records),
                      'dependency_audit': 'PASS'}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    build(parser.parse_args().out)

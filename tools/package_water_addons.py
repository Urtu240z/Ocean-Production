"""Reproducible addon ZIPs from a committed Git tree, never the working copy.

Build: python -B tools/package_water_addons.py --ref master --out <new-directory>
After testing/publishing: repeat with --verify --tests <results.json>.
Verification reconstructs ZIP bytes from the published tree and checks the saved
ZIPs, including the exact archive hashes covered by the installation tests.
"""
from pathlib import Path, PurePosixPath
import argparse
import datetime
import hashlib
import io
import json
import re
import subprocess
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SKIP_DIRS = {'.godot', '.git', '__pycache__', 'godot-cpp', 'build', 'perf1'}
SKIP_SUFFIXES = {'.obj', '.lib', '.exp', '.pdb', '.tmp', '.pyc'}
TEXT_SUFFIXES = {'.gd', '.tscn', '.tres', '.gdshader', '.gdshaderinc',
                 '.glsl', '.inc', '.source', '.gdextension', '.cfg', '.example'}
NATIVE_LIBRARIES = {
    'ocean_query_native.windows.template_release.x86_64.dll',
    'ocean_query_native.linux.template_release.x86_64.so',
}
PACKAGES = {'Ocean_Addon.zip': ['ocean'], 'JetSki_Addon.zip': ['jet_ski'],
            'WaterRace_Addons_Complete.zip': ['ocean', 'jet_ski']}


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def source_tree(ref):
    commit = git('rev-parse', '--verify', ref + '^{commit}').decode().strip()
    raw = git('archive', '--format=tar', commit, 'addons/ocean', 'addons/jet_ski')
    payloads, excluded = {}, []
    with tarfile.open(fileobj=io.BytesIO(raw)) as archive:
        for item in archive:
            if item.isdir():
                continue
            if not item.isfile():
                raise ValueError('Unsupported non-regular source: ' + item.name)
            path = PurePosixPath(item.name)
            if (any(part in SKIP_DIRS for part in path.parts)
                    or path.suffix.lower() in SKIP_SUFFIXES
                    or path.name in {'.sconsign.dblite', '.gitignore'}
                    or path.name.startswith('~')
                    or ('bin' in path.parts and path.name not in NATIVE_LIBRARIES)):
                excluded.append(item.name)
                continue
            payloads[item.name] = archive.extractfile(item).read()
    return commit, dict(sorted(payloads.items())), excluded


def audit(payloads):
    """Audit literal case-sensitive paths. Keep dynamic resource folders whole."""
    failures = []
    for name, data in payloads.items():
        if PurePosixPath(name).suffix not in TEXT_SUFFIXES:
            continue
        for resource in re.findall(r'res://[^\s"\'<>]+', data.decode('utf-8')):
            target = resource[6:]
            if not target.startswith(('addons/ocean/', 'addons/jet_ski/')):
                failures.append([name, 'external resource', resource])
            elif name.startswith('addons/ocean/') and target.startswith('addons/jet_ski/'):
                failures.append([name, 'Ocean depends on Jet Ski', resource])
            elif '%' not in target and not target.endswith('/') and target not in payloads:
                failures.append([name, 'missing or case-mismatched', resource])
    if failures:
        raise ValueError(json.dumps(failures, indent=2))
    for library in NATIVE_LIBRARIES:
        assert any(name.endswith('/bin/' + library) for name in payloads), library
    return {'literal_resource_paths': 'PASS', 'ocean_independent_of_jet_ski': True,
            'runtime_dynamic_paths': 'Preserved in full; exercised by clean installation smoke',
            'export_include_filter': '*.glsl,*.inc,*.source'}


def zip_bytes(payloads, addons, readme, day):
    buffer = io.BytesIO()
    stamp = (day.year, day.month, day.day, 0, 0, 0)
    selected = {name: data for name, data in payloads.items()
                if any(name.startswith('addons/' + addon + '/') for addon in addons)}
    selected['README_INSTALLATION.md'] = readme
    with zipfile.ZipFile(buffer, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(selected.items()):
            entry = zipfile.ZipInfo(name, stamp)
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, data, compresslevel=9)
    return buffer.getvalue(), selected


def extract_checked(archive_path, destination, expected):
    with zipfile.ZipFile(archive_path) as archive:
        assert archive.testzip() is None
        assert set(archive.namelist()) == set(expected)
        for name in archive.namelist():
            path = PurePosixPath(name)
            assert not path.is_absolute() and '..' not in path.parts
            content = archive.read(name)
            assert content == expected[name], name
            target = destination.joinpath(*path.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)


def build(options):
    destination = options.out.resolve()
    if destination == ROOT or ROOT in destination.parents:
        raise SystemExit('Release must be outside the versioned source tree.')
    if not options.verify and destination.exists():
        raise SystemExit('Choose a new output directory; existing releases are preserved.')
    commit, payloads, excluded = source_tree(options.ref)
    dependency_audit = audit(payloads)
    day = datetime.date.fromisoformat(options.date)
    readme = git('show', commit + ':tools/README_WATER_ADDONS_INSTALLATION.md')
    if not options.verify:
        destination.mkdir(parents=True)
    packages = []
    selected_packages = {}
    for filename, addons in PACKAGES.items():
        data, selected = zip_bytes(payloads, addons, readme, day)
        target = destination / filename
        if options.verify:
            assert target.read_bytes() == data, 'Archive differs from committed tree: ' + filename
            with zipfile.ZipFile(target) as archive:
                assert archive.testzip() is None
        else:
            target.write_bytes(data)
        selected_packages[filename] = selected
        packages.append({'name': filename, 'addons': addons, 'files': len(selected),
                         'bytes': len(data), 'sha256': sha(data), 'path': str(target),
                         'requires': ['Ocean_Addon.zip'] if addons == ['jet_ski'] else []})
    if not options.verify:
        # Extract the archives themselves; never copy the original working tree.
        for filename, folder in [('Ocean_Addon.zip', 'OceanOnly'),
                                 ('WaterRace_Addons_Complete.zip', 'TestAddons'),
                                 ('JetSki_Addon.zip', 'JetSkiArchive')]:
            extract_checked(destination / filename, destination / folder, selected_packages[filename])
        config = payloads['addons/jet_ski/examples/project.godot.example'].decode()
        (destination / 'TestAddons/project.godot').write_text(config, encoding='utf-8')
        ocean_config = config.replace('res://addons/jet_ski/examples/ocean_jet_ski_demo.tscn',
                                      'res://addons/ocean/ocean.tscn')
        ocean_config = ocean_config.replace('enabled=PackedStringArray("res://addons/jet_ski/plugin.cfg")',
                                            'enabled=PackedStringArray()')
        (destination / 'OceanOnly/project.godot').write_text(ocean_config, encoding='utf-8')
    tests = json.loads(options.tests.read_text(encoding='utf-8-sig')) if options.tests else {'status': 'PENDING'}
    if options.tests:
        assert tests['status'] == 'PASS'
        assert tests['zip_sha256'] == {row['name']: row['sha256'] for row in packages}
    manifest = {'godot': '4.7.1', 'gdextension_compatibility_minimum': '4.7',
                'supported_minimum': '4.7.1', 'source_commit': commit, 'date': day.isoformat(),
                'addons': ['Ocean V4', 'Jet Ski'], 'packages': packages,
                'native_sha256': {name: sha(data) for name, data in payloads.items()
                                  if PurePosixPath(name).name in NATIVE_LIBRARIES},
                'dependencies': {'Ocean': ['Godot 4.7.1 Forward+ / RenderingDevice', 'x86_64 AVX2 CPU'],
                                 'Jet Ski': ['Ocean', 'Jolt Physics', 'physics 60 Hz']},
                'platforms_validated': tests.get('platforms_validated', []),
                'pending': ['Steam Deck hardware', 'Linux/AMD graphical render and game export'],
                'audit': dependency_audit, 'tests': tests,
                'excluded_tracked_files': excluded,
                'files': [{'path': name, 'bytes': len(data), 'sha256': sha(data)}
                          for name, data in payloads.items()],
                'reproducibility': 'Committed blobs only; sorted paths; fixed date/mode; Python stdlib zip/deflate',
                'source_addon_trees': {addon: git('rev-parse', commit + ':addons/' + addon).decode().strip()
                                       for addon in ['ocean', 'jet_ski']}}
    (destination / 'README_INSTALLATION.md').write_bytes(readme)
    (destination / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'source_commit': commit, 'packages': packages,
                      'audit': dependency_audit, 'tests': tests['status']}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--ref', default='master')
    parser.add_argument('--date', default=datetime.date.today().isoformat())
    parser.add_argument('--verify', action='store_true')
    parser.add_argument('--tests', type=Path)
    build(parser.parse_args())

"""Summarize installation evidence; does not build or modify addon archives.

Run after graphical imports/smokes, Linux --native-only and e2_pack_audit.py.
The smoke harness is copied to each extracted project's root as release_smoke.gd.
"""
from pathlib import Path, PurePosixPath
import argparse
import hashlib
import json
import re


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def check(folder):
    manifest = read(folder / 'manifest.json')
    hashes = {}
    for archive in manifest['packages']:
        path = folder / archive['name']
        hashes[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
        assert hashes[path.name] == archive['sha256']
    logs = {}
    for path in sorted(folder.glob('*.log')):
        text = path.read_text(encoding='utf-8-sig', errors='replace')
        errors = re.findall(r'^.*(?:ERROR:|SCRIPT ERROR:|Parse Error|ObjectDB instances were leaked|resources still in use).*$', text, re.M)
        assert not errors, (path.name, errors[:4])
        logs[path.name] = {'bytes': path.stat().st_size, 'errors': len(errors),
                           'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
    expected_logs = ['import_OceanOnly', 'import_TestAddons', 'smoke_OceanOnly',
                     'smoke_TestAddons', 'linux_OceanOnly', 'linux_TestAddons',
                     'production', 'export_windows', 'export_runtime']
    for name in expected_logs:
        assert name + '.stdout.log' in logs and name + '.stderr.log' in logs, name
    results = {}
    for project, kind in [('OceanOnly','ocean'), ('TestAddons','complete'),
                          ('OceanOnly','native'), ('TestAddons','native')]:
        data = read(folder / project / ('smoke_' + kind + '.json'))
        assert not data['failures']
        assert data['physics_hz'] == 60
        if kind != 'native':
            assert data['driver'] == 'd3d12'
            assert data['async']['mode'] == 1 and data['async']['workers'] == 3
            assert data['async']['failures'] == 0
        if kind == 'complete':
            assert data['native_batches'] > 0 and data['propulsion']
        results[project + '_' + kind] = data
    assert not (folder / 'OceanOnly/addons/jet_ski').exists()
    assert not (folder / 'OceanOnly/validation').exists()
    assert not (folder / 'TestAddons/validation').exists()
    for project in ['OceanOnly', 'TestAddons']:
        for name, expected in manifest['native_sha256'].items():
            assert hashlib.sha256((folder / project / name).read_bytes()).hexdigest() == expected
    production = read(folder / 'production_smoke.json')
    assert not production['failures'] and production['workers'] == 3
    assert production['physics_hz'] == 60 and production['geometry_uploads'] == 1
    audit = read(folder / 'export_windows_audit.json')
    assert audit['passed'] and audit['all_entry_md5_verified']
    names = {row['path'] for row in audit['entries']}
    required = [row['path'] for row in manifest['files']
                if PurePosixPath(row['path']).suffix in {'.glsl','.inc','.source'}]
    missing = sorted(set(required) - names)
    assert not missing, missing
    return {'status':'PASS', 'tested_source_commit':manifest['source_commit'],
            'tested_addon_trees':manifest['source_addon_trees'], 'zip_sha256':hashes,
            'platforms_validated':['Windows x86_64 / RTX 4070 Laptop / D3D12 Forward+',
                                   'Windows x86_64 export PCK + runtime startup',
                                   'Linux x86_64 Ubuntu 22.04 WSL2 native class loading'],
            'smokes':results, 'production':production, 'logs':logs,
            'export':{'pck_files':audit['files'], 'runtime_shader_sources':len(required),
                      'all_shader_sources_present':True, 'native_sha256':audit['native_sha256']},
            'limits':['No Steam Deck hardware execution', 'No Linux/AMD graphical render or Linux game export in this release',
                      'Smoke exercises startup/propulsion/reset; it is not a full gameplay or visual feature matrix'],
            'archives_extracted_and_crc_verified':True}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('release', type=Path)
    args = parser.parse_args()
    result = check(args.release)
    destination = args.release / 'test_results.json'
    destination.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'status':result['status'], 'export':result['export'], 'result':str(destination)}))

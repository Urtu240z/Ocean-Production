from pathlib import Path
import hashlib
import json
import re
import shutil
import subprocess
import zipfile

root = Path(__file__).resolve().parents[1]
evidence = root / 'temp/production_preset_20261016'
evidence.mkdir(parents=True, exist_ok=True)
preset = root / 'addons/ocean/presets/ocean_production'
manifest = json.loads((preset / 'source_manifest.json').read_text(encoding='utf-8'))

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def local(path):
    assert path.startswith('res://')
    result = (root / path[6:]).resolve()
    assert result.is_relative_to(root.resolve())
    return result

mapping = {**manifest['root_path_map'], **manifest['external_assets']}
assets = []
for src, dst in manifest['external_assets'].items():
    source, target = local(src), local(dst)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    assets.append({'original': src, 'path': dst, 'source_sha256': sha(source)})
    original_import = Path(str(source) + '.import')
    if original_import.is_file():
        clean_import = root / 'temp/phase_e1_20261016/clean_windows' / target.relative_to(root)
        clean_import = Path(str(clean_import) + '.import')
        new_import = Path(str(target) + '.import')
        previous = new_import if new_import.exists() else clean_import
        assert previous.exists(), 'Import asset once in clean project to obtain a distinct Godot UID'
        uid = re.search(r'^uid="([^"]+)"', previous.read_text(encoding='utf-8'), re.M).group(1)
        text = original_import.read_text(encoding='utf-8')
        text = text.replace(src, dst).replace(hashlib.md5(src.encode()).hexdigest(), hashlib.md5(dst.encode()).hexdigest())
        text = re.sub(r'^uid="[^"]+"', 'uid="' + uid + '"', text, flags=re.M)
        new_import.write_text(text, encoding='utf-8', newline='\n')

for path in preset.rglob('*'):
    if path.suffix not in ('.tres', '.tscn'):
        continue
    text = path.read_text(encoding='utf-8-sig')
    for src, dst in mapping.items():
        if src:
            text = text.replace('"' + src + '"', '"' + dst + '"')
    # New standalone resources must not reuse source scene/profile UIDs.
    text = re.sub(r' uid="uid://[^"]+"', '', text)
    references = re.findall(r'"(res://[^"\n]+)"', text)
    assert all(p.startswith('res://addons/ocean/') for p in references), (path, references)
    path.write_text(text, encoding='utf-8', newline='\n')

# Preserve the disabled, map-specific legacy bake without installing its old
# global classes into either addon or pretending it fits the destination map.
archive_files = {root / 'validation/coastal_bake.tres'}
archive_files.update((root / 'validation/p4_paradise').glob('*.gd'))
archive_files.update((root / 'validation/p4_paradise').glob('*.gd.uid'))
pending = [root / 'validation/coastal_bake.tres']
while pending:
    path = pending.pop()
    if path.suffix not in ('.tres', '.gd', '.tscn'):
        continue
    for ref in re.findall(r'"(res://[^"\n]+)"', path.read_text(encoding='utf-8-sig')):
        dep = local(ref)
        if dep.is_file() and not ref.startswith('res://addons/ocean/') and dep not in archive_files:
            archive_files.add(dep)
            pending.append(dep)
head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
rows = [{'path': p.relative_to(root).as_posix(), 'bytes': p.stat().st_size, 'sha256': sha(p)}
        for p in sorted(archive_files)]
archive_path = evidence / 'coastal_reference.zip'
with zipfile.ZipFile(archive_path, 'w', compression=zipfile.ZIP_DEFLATED) as output:
    for row in rows:
        output.write(root / row['path'], row['path'])
    output.writestr('ARCHIVE_MANIFEST.json', json.dumps({'source_head': head, 'files': rows,
        'note': 'Inactive original-island legacy bake and original source paths. Not an Ocean addon dependency; do not enable this bake on an unrelated terrain. The source revision retains original context.'}, indent=2))
with zipfile.ZipFile(archive_path) as check:
    for row in rows:
        assert hashlib.sha256(check.read(row['path'])).hexdigest() == row['sha256']

lines = ['# Valores efectivos de Ocean Production', '',
    'Origen: `gameplay/jet_ski_ocean.tscn` → `Production/Ocean`, una vez preparado el juego.', '',
    'Los perfiles `.tres` contienen los mismos valores guardados e incrustados de producción.',
    'También hay ajustes del nodo que no pertenecen a esos perfiles. Para conservarlos todos,',
    'instancia `ocean_production.tscn`, o reproduce la tabla siguiente en tu Ocean existente.', '',
    '| Propiedad del nodo | Valor de producción |', '| --- | --- |']
lines += [f'| `{key}` | `{value}` |' for key, value in sorted(manifest['node_values'].items())]
lines += ['', '## Recursos independientes', '']
lines += [f'- `{name}.tres`' for name in sorted(manifest['resources'])]
lines += ['', '## Iluminación y costa', '',
    '`lighting_environment.tres` y `lighting_reference.tscn` conservan el entorno/HDR y el sol',
    'originales como referencia opcional. Tu Sky3D y tu iluminación pueden producir otra imagen',
    'aunque los valores de Ocean sean iguales. Asigna a Ocean el sol que utilices en tu nivel.', '',
    'La escena del jet ski desactiva `coastal` y `breakers` al arrancar; el preset conserva ese',
    'estado efectivo. El perfil de breakers se entrega igualmente. El bake costero antiguo es',
    'específico de la isla original y depende de clases antiguas de validación: se conserva',
    'aparte en `resource_exports/ocean_production_legacy/coastal_reference.zip`, con rutas y',
    'hashes verificados. No es necesario para este preset ni se activa en el otro mapa.', '',
    '`visual_water_profile = 1` conserva el perfil PHYSICS_ALIGNED que el integrador original',
    'aplica en runtime. Se ha expuesto ese selector para poder guardarlo en una escena portable,',
    'sin cambiar el valor predeterminado del addon ni los cálculos FFT.', '']
(preset / 'AJUSTES_OCEAN.md').write_text('\n'.join(lines), encoding='utf-8')
result = {'files': [{'path': p.relative_to(root).as_posix(), 'bytes': p.stat().st_size, 'sha256': sha(p)}
                    for p in sorted(preset.rglob('*')) if p.is_file()],
          'source_assets': assets, 'legacy_archive': {'path': str(archive_path), 'bytes': archive_path.stat().st_size,
          'sha256': sha(archive_path), 'entries': len(rows)}}
(evidence / 'preset_files.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
print(json.dumps({'preset_files': len(result['files']), 'preset_bytes': sum(x['bytes'] for x in result['files']),
    'legacy_archive_bytes': archive_path.stat().st_size, 'external_assets': len(assets)}, indent=2))

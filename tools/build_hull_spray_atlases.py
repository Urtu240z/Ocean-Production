"""Build bounded, shared GPU atlases from the supplied PNG sequences.

Run with Pillow available. Originals in Splash_2/3/4 remain untouched.
"""
from pathlib import Path
import hashlib
import json
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'addons/jet_ski/common/visual/hull_spray/textures'


def build(index, tile_size, columns):
    paths = sorted((ROOT / f'Splash_{index}').glob('*.png'))
    assert paths, f'Missing Splash_{index}'
    boxes = []
    for path in paths:
        with Image.open(path) as image:
            boxes.append(image.getchannel('A').point(lambda a: 255 if a > 2 else 0).getbbox())
            source_size = image.size
    box = (max(0, min(b[0] for b in boxes)-8), max(0, min(b[1] for b in boxes)-8),
           min(source_size[0], max(b[2] for b in boxes)+8), min(source_size[1], max(b[3] for b in boxes)+8))
    scale = min((tile_size[0]-8)/(box[2]-box[0]), (tile_size[1]-8)/(box[3]-box[1]))
    resized = (round((box[2]-box[0])*scale), round((box[3]-box[1])*scale))
    margin = ((tile_size[0]-resized[0])//2, (tile_size[1]-resized[1])//2)
    rows = (len(paths)+columns-1)//columns
    atlas = Image.new('RGBA', (columns*tile_size[0], rows*tile_size[1]))
    digest = hashlib.sha256()
    for i, path in enumerate(paths):
        digest.update(path.read_bytes())
        with Image.open(path) as source:
            frame = source.convert('RGBA').crop(box).resize(resized, Image.Resampling.LANCZOS)
        atlas.paste(frame, ((i % columns)*tile_size[0]+margin[0], (i//columns)*tile_size[1]+margin[1]))
    path = OUTPUT / f'splash_{index}_atlas.png'
    atlas.save(path)
    # Keep a fixed source-space anchor across all frames, never crop per frame.
    pivot_source = (950, 535) if index == 2 else (source_size[0]*0.5, min(b[1] for b in boxes))
    pivot = [((pivot_source[a]-box[a])*scale+margin[a])/tile_size[a] for a in (0, 1)]
    import_path = path.with_suffix('.png.import')
    if not import_path.exists():
        relative = 'res://' + path.relative_to(ROOT).as_posix()
        cache = f'res://.godot/imported/{path.name}-{hashlib.md5(relative.encode()).hexdigest()}.s3tc.ctex'
        import_path.write_text(f'''[remap]
importer="texture"
type="CompressedTexture2D"
path.s3tc="{cache}"
metadata={{"imported_formats": ["s3tc_bptc"], "vram_texture": true}}
[deps]
source_file="{relative}"
dest_files=["{cache}"]
[params]
compress/mode=2
compress/high_quality=true
compress/lossy_quality=0.7
mipmaps/generate=false
process/fix_alpha_border=true
process/premult_alpha=false
process/size_limit=0
detect_3d/compress_to=0
''', encoding='utf-8')
    return {'frames': len(paths), 'grid': [columns, rows], 'tile': tile_size,
            'pivot': pivot, 'crop': box, 'source_size': source_size,
            'source_sha256': digest.hexdigest(), 'atlas_size': atlas.size}


if __name__ == '__main__':
    OUTPUT.mkdir(parents=True, exist_ok=True)
    info = {str(i): build(i, size, columns) for i, size, columns in
            [(2, (384, 384), 6), (3, (256, 640), 8), (4, (256, 640), 6)]}
    (OUTPUT / 'atlas_info.json').write_text(json.dumps(info, indent=2), encoding='utf-8')
    print(json.dumps({i: {'frames': v['frames'], 'atlas': v['atlas_size']} for i, v in info.items()}))

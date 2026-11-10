#!/usr/bin/env python3
"""Package the approved master into macOS icon representations, preserving alpha."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
MASTER = ROOT / 'Branding/orbit-icon-master.png'
RESOURCES = ROOT / 'OrbitApp/Resources'


def resize(size, destination):
    subprocess.run(['/usr/bin/sips', '-z', str(size), str(size), str(MASTER),
                    '--out', str(destination)], check=True, stdout=subprocess.DEVNULL)


def main():
    RESOURCES.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='orbit-icon-') as temporary:
        iconset = Path(temporary) / 'OrbitAppIcon.iconset'
        iconset.mkdir()
        for size in [16, 32, 128, 256, 512]:
            resize(size, iconset / f'icon_{size}x{size}.png')
            resize(size * 2, iconset / f'icon_{size}x{size}@2x.png')
        subprocess.run(['/usr/bin/iconutil', '-c', 'icns', str(iconset),
                        '-o', str(RESOURCES / 'OrbitAppIcon.icns')], check=True)
    resize(256, RESOURCES / 'OrbitLogo.png')
    print('Packaged OrbitAppIcon.icns (16–1024 px) and OrbitLogo.png')


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Check actual GPU output packing at preset, custom and Retina resolutions."""
import numpy as np
from render_metal import MetalRenderer, MANIFEST


def main():
    renderer = MetalRenderer()
    scene = next(s for s in MANIFEST['scenes'] if s['testScene'])
    options = {'brightness': 1, 'flipU': 0, 'flipV': 0, 'angleOffset': 0}
    reference, _ = renderer.render(scene, 3840, 2160, view=2,
                                   overrides={**options, 'testPattern': 0})
    for width, height in [(1280, 720), (1920, 1080), (2560, 1440),
                          (3840, 2160), (1024, 576), (3456, 1944)]:
        white, _ = renderer.render(scene, width, height, view=2,
                                   overrides={**options, 'testPattern': 5})
        # Five scaled rectangles form the LED payload. Everything else stays opaque black.
        x = (np.arange(width) + 0.5) / width
        y = (np.arange(height) + 0.5) / height
        active = ((x[None, :] < 3564 / 3840) & (y[:, None] < 1200 / 2160)) | (
            (x[None, :] < 1188 / 3840) & (y[:, None] >= 1200 / 2160) & (y[:, None] < 1500 / 2160))
        assert np.all(white[:, :, 3] == 255), 'Output is not opaque'
        assert np.all(white[~active, :3] == 0), f'Packing spills into black area at {width}'
        assert np.all(white[active, :3] == 255), f'Content is clipped at {width}'
        sectors, _ = renderer.render(scene, width, height, view=2,
                                     overrides={**options, 'testPattern': 0})
        # Each of the five row identities must survive resizing, including the short last row.
        for row in range(5):
            ref_x, ref_y = 300, row * 300 + 150
            color = sectors[int(ref_y * height / 2160), int(ref_x * width / 3840), :3]
            assert np.max(np.abs(color.astype(int) - reference[ref_y, ref_x, :3])) <= 1
        print(f'PASS: {width}×{height} — 5 segments, no clipping, opaque black padding')

    # Every production scene must use the same LED packing, never ring preview coordinates.
    for scene in MANIFEST['scenes']:
        strip, _ = renderer.render(scene, 15444, 300, view=0, seconds=6)
        packed, _ = renderer.render(scene, 3840, 2160, view=2, seconds=6)
        expected = np.zeros_like(packed)
        expected[:, :, 3] = 255
        for row in range(5):
            length = 3564 if row < 4 else 1188
            expected[row*300:(row+1)*300, :length, :3] = strip[:, row*3564:row*3564+length, :3]
        error = np.abs(packed.astype(int)-expected.astype(int))
        assert error.max() <= 2, f'{scene["id"]}: LED output differs from unpacked content: {error.max()}'
        assert np.any(packed[:1500, :, :3] > 0), f'{scene["id"]}: empty output'
        print(f'PASS: {scene["id"]} — full 4K LED/strip pixel comparison, max error {error.max()}')


if __name__ == '__main__':
    main()

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


if __name__ == '__main__':
    main()

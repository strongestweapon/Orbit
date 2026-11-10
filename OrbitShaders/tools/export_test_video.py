#!/usr/bin/env python3
"""Create a 4K/60 test video: nine static patterns, then one full marker revolution."""
import subprocess
from PIL import Image
from render_metal import ROOT,MANIFEST,MetalRenderer

def main():
    renderer=MetalRenderer();scene=next(s for s in MANIFEST['scenes'] if s['testScene'])
    folder=ROOT/'previews/test-patterns';folder.mkdir(exist_ok=True)
    # 9 static patterns at two seconds each; moving marker at 0.08 turns/s for 12.5s.
    order=[0,1,2,3,4,5,6,8,9]
    dest=ROOT/'previews/LED-test-patterns-3840x2160-60fps.mp4'
    cmd=['ffmpeg','-hide_banner','-loglevel','error','-y','-f','rawvideo','-pixel_format','rgba',
      '-video_size','3840x2160','-framerate','60','-i','-','-an','-c:v','libx264','-preset','veryfast',
      '-crf','16','-vf','scale=out_color_matrix=bt709','-pix_fmt','yuv420p',
      '-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709',
      '-movflags','+faststart',str(dest)]
    proc=subprocess.Popen(cmd,stdin=subprocess.PIPE)
    try:
        for pattern in order:
            pixels,_=renderer.render(scene,3840,2160,2,overrides={'testPattern':pattern})
            Image.fromarray(pixels,'RGBA').save(folder/f'{pattern:02d}.png')
            frame=pixels.tobytes()
            for _ in range(120):proc.stdin.write(frame)
            print('Exported test pattern',pattern,flush=True)
        for i in range(750):
            pixels,_=renderer.render(scene,3840,2160,2,seconds=i/60,overrides={'testPattern':7,'markerWidth':24})
            if i==0:Image.fromarray(pixels,'RGBA').save(folder/'07.png')
            proc.stdin.write(pixels.tobytes())
    finally:proc.stdin.close()
    if proc.wait()!=0:raise RuntimeError('Encoding failed')
    print(dest,flush=True)

if __name__=='__main__':main()

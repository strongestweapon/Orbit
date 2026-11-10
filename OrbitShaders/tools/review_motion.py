#!/usr/bin/env python3
"""Compare source timing with the real Metal generator; source pixels never enter a shader."""
import json, subprocess
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from render_metal import ROOT, MANIFEST, MetalRenderer

def metrics(frames, fps=12):
    y = frames @ [.2126,.7152,.0722]
    phase = np.unwrap(np.angle(np.fft.rfft(y,axis=1)[:,1]))
    rotation = -np.polyfit(np.arange(len(y))/fps,phase,1)[0]/(2*np.pi)
    return {'meanLuma':float(y.mean()),'frameDelta':float(abs(np.diff(frames,axis=0)).mean()),
            'halfSecondDelta':float(abs(frames[6:]-frames[:-6]).mean()),
            'lowFrequencyTurnsPerSecond':float(rotation)}

def main():
    r=MetalRenderer();review=ROOT/'review'
    source=np.load(review/'source-motion.npz')['profiles']/255
    report=json.loads((review/'before-motion.json').read_text())
    for scene in MANIFEST['scenes'][:5]:
        generated=[]
        for i in range(96):
            frame,_=r.render(scene,512,24,0,i/12+2)
            generated.append(frame[:,:,:3].mean(0)/255)
        report[scene['id']]['after']=metrics(np.array(generated))
    (review/'motion-comparison.json').write_text(json.dumps(report,indent=2)+'\n')
    scene=next(s for s in MANIFEST['scenes'] if s['id']=='05_cyan_halo')
    early=report[scene['id']]['after']['lowFrequencyTurnsPerSecond']
    assert -.27 < early < -.21, ('Cyan direction / early speed regression',early)
    late=[]
    for i in range(72):
        frame,_=r.render(scene,512,24,0,i/24+17)
        late.append(frame[:,:,:3].mean(0)/255)
    late_rate=metrics(np.array(late),24)['lowFrequencyTurnsPerSecond']
    assert late_rate < -.8, ('Cyan acceleration missing',late_rate)
    # Actual rendered continuity across the installation's smooth speed reset.
    a,_=r.render(scene,512,24,0,25.999);b,_=r.render(scene,512,24,0,26.001)
    seam_delta=float(abs(a.astype(float)-b.astype(float)).mean())
    assert seam_delta < 1, ('Temporal cycle jumps',seam_delta)
    report['cyanTimingCheck']={'earlyTurnsPerSecond':early,'lateTurnsPerSecond':late_rate,
                              'cycleBoundaryMeanByteDifference':seam_delta,'passed':True}
    (review/'motion-comparison.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report['cyanTimingCheck'],indent=2),flush=True)
    # 20-second video at the source's 24 fps, with identical clock positions on both sides.
    w,h,fps=640,360,24
    reader=subprocess.Popen(['ffmpeg','-loglevel','error','-ss','106','-i',str(ROOT.parent/MANIFEST['referenceVideo']),
       '-vf','scale=640:360,fps=24','-f','rawvideo','-pix_fmt','rgb24','-'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
    dest=review/'cyan-motion-comparison.mp4'
    encoder=subprocess.Popen(['ffmpeg','-loglevel','error','-y','-f','rawvideo','-pix_fmt','rgb24',
        '-s','1280x420','-r',str(fps),'-i','-','-an','-c:v','libx264','-preset','fast','-crf','18',
        '-pix_fmt','yuv420p','-movflags','+faststart',str(dest)],stdin=subprocess.PIPE)
    font=ImageFont.truetype('/System/Library/Fonts/Menlo.ttc',16)
    title=Image.new('RGB',(1280,420),'#101217');d=ImageDraw.Draw(title)
    d.text((20,12),'ORIGINAL / 106-126 seconds / 1x',font=font,fill='white')
    d.text((660,12),'LIVE METAL / equations only / 1x',font=font,fill='white')
    d.text((20,397),'Same elapsed time; rotation and acceleration comparison',font=font,fill='#aab3bf')
    base=np.array(title)
    try:
        for i in range(20*fps):
            data=reader.stdout.read(w*h*3)
            if len(data)!=w*h*3:raise RuntimeError('Source video ended early')
            pixels,_=r.render(scene,w,h,1,i/fps)
            frame=base.copy();frame[36:396,:w]=np.frombuffer(data,np.uint8).reshape(h,w,3)
            frame[36:396,w:]=pixels[:,:,:3]
            encoder.stdin.write(frame.tobytes())
            if i in [3*fps,9*fps,17*fps]:Image.fromarray(frame).save(review/f'cyan-comparison-{i//fps}s.jpg')
    finally:
        reader.stdout.close();reader.terminate();reader.wait()
        encoder.stdin.close()
    assert encoder.wait()==0
    print(dest,flush=True)

if __name__=='__main__':main()

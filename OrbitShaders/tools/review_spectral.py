#!/usr/bin/env python3
"""Render the code-only scene and check temporal continuity beyond whole-ring rotation."""
import json
import numpy as np
from PIL import Image, ImageDraw
from render_metal import ROOT, MANIFEST, MetalRenderer

scene=next(s for s in MANIFEST['scenes'] if s['id']=='07_spectral_fragments')
renderer=MetalRenderer()
folder=ROOT/'review'/'spectral-code'
folder.mkdir(parents=True,exist_ok=True)
frames=[]
for t in [0,1/30,3,10]:
    pixels,_=renderer.render(scene,2048,96,0,t)
    frames.append(pixels[:,:,:3].astype(np.float32)/255)
    if t != 1/30:
        ring,_=renderer.render(scene,1280,720,1,t)
        Image.fromarray(ring).save(folder/f't{t}.png')
a,b=frames[0],frames[2]
# Full RGB correlation, summed over radial pixels: find the best possible rigid rotation.
fa=np.fft.rfft(a,axis=1);fb=np.fft.rfft(b,axis=1)
corr=np.fft.irfft(np.sum(np.conj(fa)*fb,axis=(0,2)),n=a.shape[1])
shift=int(np.argmax(corr))
residual=float(np.abs(a-np.roll(b,-shift,axis=1)).mean())
step=float(np.abs(a-frames[1]).mean());long=float(np.abs(a-frames[3]).mean())
one_second,_=renderer.render(scene,2048,96,0,1)
visible_motion=float(np.abs(a-one_second[:,:,:3].astype(np.float32)/255).mean())
repeat,_=renderer.render(scene,2048,96,0,0)
assert np.array_equal((a*255).round().astype(np.uint8),repeat[:,:,:3]),'Paused clock must hold same image'
assert residual>0.01,'Only rigid rotation detected'
small_delta,_=renderer.render(scene,2048,96,0,0.001)
small_step=float(np.abs(a-small_delta[:,:,:3].astype(np.float32)/255).mean())
# Travelling subpixel lines can change many pixels in 1/30s; inspect a 1ms step
# to distinguish continuous travel from frame-sized jumps.
assert 0<small_step<step*0.12,'Discontinuous change at a subframe time step'
assert visible_motion>0.03,'Motion at default speed looks static within one second'
report={'scene':scene['id'],'textureInputs':0,'sameClockSameFrame':True,
        'oneMillisecondMeanDifference':small_step,'oneFrameMeanDifference':step,'oneSecondMeanDifference':visible_motion,'tenSecondMeanDifference':long,
        'bestRigidShiftPixels':shift,'nonRigidMeanDifference':residual,'passed':True}
(folder/'motion-validation.json').write_text(json.dumps(report,indent=2)+'\n')
# Side-by-side is only an inspection artifact; the reference is not passed to the shader.
ref=Image.open(ROOT.parent/'OrbitApp/Resources/spectral-fragments-reference.png').convert('RGB')
actual=Image.open(folder/'t3.png').convert('RGB')
canvas=Image.new('RGB',(1280,520),(10,10,10));draw=ImageDraw.Draw(canvas)
ref=ref.crop((116,44,516,444)).resize((476,476),Image.Resampling.LANCZOS)
actual=actual.crop((340,60,940,660)).resize((476,476),Image.Resampling.LANCZOS)
canvas.paste(ref,(80,35));canvas.paste(actual,(722,35))
draw.text((16,10),'SUPPLIED STILL (REFERENCE ONLY)',fill=(220,220,220))
draw.text((730,10),'CODE ONLY / t=3s',fill=(220,220,220))
canvas.save(folder/'reference-vs-code.jpg',quality=95)
print(json.dumps(report,indent=2))

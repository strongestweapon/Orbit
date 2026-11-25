#!/usr/bin/env python3
"""Check Golden Drift's visible default motion using actual Metal pixels."""
import json
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw
from render_metal import ROOT, MANIFEST, MetalRenderer


def turn_rate(renderer, scene, speed=None):
    profiles=[]
    for i in range(97):
        overrides={} if speed is None else {'phaseTime':i/8*speed}
        pixels,_=renderer.render(scene,512,24,0,i/8,overrides)
        profiles.append(pixels[:,:,:3].mean(axis=0) @ [.2126,.7152,.0722])
    phase=np.unwrap(np.angle(np.fft.rfft(np.array(profiles),axis=1)[:,1]))
    return float(-np.polyfit(np.arange(len(phase))/8,phase,1)[0]/(2*np.pi))


def main():
    renderer=MetalRenderer()
    scene=next(s for s in MANIFEST['scenes'] if s['id']=='08_golden_drift')
    rate=turn_rate(renderer,scene)
    expected=scene['defaultClockSpeed']*scene['defaults']['gapMotion']*.025*4
    assert abs(rate-expected)<.002,('Default drift',rate,expected)
    doubled=turn_rate(renderer,scene,scene['defaultClockSpeed']*2)
    assert 1.8<doubled/rate<2.2,('Speed control',rate,doubled)
    a,_=renderer.render(scene,512,24,0,0)
    b,_=renderer.render(scene,512,24,0,6)
    assert np.abs(a.astype(float)-b).mean()>8, 'No visible motion over six seconds'
    frozen,_=renderer.render(scene,512,24,0,6,{'phaseTime':0})
    assert np.array_equal(a,frozen), 'Frozen host clock must not animate'
    packed,_=renderer.render(scene,3840,2160,2,6)
    assert not packed[1500:,:,:3].any() and not packed[:1500,3564:,:3].any()
    assert not packed[1200:1500,1188:,:3].any(), 'Unused LED pixels must remain black'
    out=ROOT.parent/'.build/golden-motion-check';out.mkdir(parents=True,exist_ok=True)
    report={'defaultTurnsPerSecond':rate,'expectedTurnsPerSecond':expected,
            'secondsPerTurn':1/rate,'doubleSpeedTurnsPerSecond':doubled,'passed':True}
    before=out/'before.metal'
    if before.exists():
        old={**scene,'id':'golden_before','metal':str(before)}
        report['beforeTurnsPerSecond']=turn_rate(renderer,old)
    (out/'result.json').write_text(json.dumps(report,indent=2)+'\n')
    sheet=Image.new('RGB',(1440,400),'#101010');draw=ImageDraw.Draw(sheet)
    for index,seconds in enumerate([0,6,12]):
        pixels,_=renderer.render(scene,480,360,1,seconds)
        sheet.paste(Image.fromarray(pixels[:,:,:3]),(index*480,30))
        draw.text((index*480+20,12),f'Golden Drift / {seconds} seconds',fill='white')
    sheet.save(out/'motion.jpg')
    print(json.dumps(report,indent=2),flush=True)

if __name__=='__main__':main()

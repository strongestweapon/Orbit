"""GPU regression checks for the quiet, causal Pulse Orbit scene."""
import numpy as np
from render_metal import MetalRenderer, MANIFEST

def validate(renderer,scene):
    errors=[]
    for accent in [0,1,2,3,4]:
        settings={} if accent==0 else dict(accentKind=accent,accentTime=1,lineCount=4 if accent==3 else 3)
        packed,_=renderer.render(scene,3840,2160,2,seconds=2.5,overrides=settings)
        strip,_=renderer.render(scene,15444,300,0,seconds=2.5,overrides=settings)
        assert np.all(packed[:,:,3]==255)
        assert not packed[1500:,:,:3].any() and not packed[:1500,3564:,:3].any()
        assert not packed[1200:1500,1188:,:3].any()
        for row in range(5):
            w=3564 if row<4 else 1188
            error=np.abs(packed[row*300:(row+1)*300,:w,:3].astype(int)-strip[:,row*3564:row*3564+w,:3].astype(int)).max()
            errors.append(int(error))
        assert max(errors)<=2,errors
        reverse,_=renderer.render(scene,15444,300,0,seconds=2.5,overrides={**settings,'flipV':1})
        assert np.abs(strip.astype(int)-reverse[::-1].astype(int)).max()<=2
        if accent:
            baseline,_=renderer.render(scene,2048,300,0,seconds=2.5,overrides={'lineCount':settings['lineCount']})
            event,_=renderer.render(scene,2048,300,0,seconds=2.5,overrides=settings)
            assert np.abs(event.astype(float)-baseline.astype(float)).mean()>0.2,('missing accent',accent)
            expired,_=renderer.render(scene,2048,300,0,seconds=10,overrides=settings)
            rested,_=renderer.render(scene,2048,300,0,seconds=10.2,overrides=settings)
            peak,_=renderer.render(scene,2048,300,0,seconds=2.7,overrides=settings)
            quiet_delta=np.abs(expired.astype(float)-rested.astype(float)).mean()
            active_delta=np.abs(event.astype(float)-peak.astype(float)).mean()
            # Base phrases are now clearly moving; a command still produces a
            # stronger change and then loses its extra illuminated footprint.
            assert quiet_delta<active_delta*0.65,('event contrast lost',accent,quiet_delta,active_delta)
            assert rested[:,:,:3].mean()<peak[:,:,:3].mean()*0.65,('event light did not decay',accent)
    for control in scene['parameters']:
        active={'accentKind':3,'accentTime':1}
        if control['id']=='attractorPosition': active['attraction']=0.8
        a,_=renderer.render(scene,2048,300,0,seconds=3,overrides={**active,control['id']:0})
        b,_=renderer.render(scene,2048,300,0,seconds=3,overrides={**active,control['id']:0.5 if control['id']=='attractorPosition' else 1})
        assert np.abs(a.astype(float)-b.astype(float)).mean()>0.05,control['id']
    a,_=renderer.render(scene,2048,300,0,seconds=1)
    b,_=renderer.render(scene,2048,300,0,seconds=5)
    assert not np.array_equal(a,b),'Quiet current must move, not freeze'
    baseline,_=renderer.render(scene,4096,300,0,seconds=2)
    energy=baseline[:,:,:3].max(axis=2)
    assert (baseline[:,:,0]>245).any() and (baseline[:,:,1]>245).any(),'Base red and white heads must be bright'
    assert (energy>100).any(axis=0).mean()<0.30,'Base phrases must leave gaps rather than form long ribbons'
    # Radial marks exist only after a command. Compare the exact same simulated
    # scene with those slots disabled, so the travelling ribbons do not count.
    original=renderer.pulse_state
    settings={'accentKind':1,'accentTime':1}
    marked,_=renderer.render(scene,4096,300,0,seconds=1.8,overrides=settings)
    def without_marks(params):
        state=original(params)
        offset=scene['uniformBuffer']['traceFloatOffset']-40
        state[offset:offset+192]=[0]*192
        return state
    renderer.pulse_state=without_marks
    unmarked,_=renderer.render(scene,4096,300,0,seconds=1.8,overrides=settings)
    renderer.pulse_state=original
    energy=np.maximum(0,marked[:,:,:3].astype(int)-unmarked[:,:,:3].astype(int)).max(axis=2)
    run=np.zeros(4096,dtype=int);longest=0
    for row in energy>100:
        run=np.where(row,run+1,0);longest=max(longest,int(run.max()))
    assert 35<longest<150,('missing or oversized triggered perpendicular strokes',longest)
    # Freeze only the simulated state to isolate the shader clock. The renderer
    # must add no scheduled brightness, length or glow pulses of its own.
    original=renderer.pulse_state
    cache={}
    def held(params):
        if not cache: cache['state']=original(params)
        return cache['state']
    renderer.pulse_state=held
    settings={'coverage':0.6,'gapMotion':1,'fragmentation':0.8}
    a,_=renderer.render(scene,2048,300,0,seconds=1,overrides=settings)
    b,_=renderer.render(scene,2048,300,0,seconds=90,overrides=settings)
    assert np.array_equal(a,b),'Shader clock/common presence must not add autonomous pulses'
    renderer.pulse_state=original
    black,_=renderer.render(scene,1024,96,0,seconds=2,overrides={'brightness':0,'accentKind':2})
    assert not black[:,:,:3].any()
    # The palette is red/white, and the halo must be dimmer than its sharp core.
    event,_=renderer.render(scene,4096,300,0,seconds=2,overrides={'accentKind':1,'accentTime':1})
    assert np.array_equal(event[:,:,1],event[:,:,2])
    energy=event[:,:,:3].max(axis=2)
    assert (energy>180).any() and ((energy>5)&(energy<45)).any()
    assert (energy>100).mean()<0.15,'Accent fills too much of LED band'
    seam,_=renderer.render(scene,15444,300,0,seconds=60,overrides={'directionDrive':0.5,'attraction':1,'attractorPosition':0})
    # Neighboring pixels can differ across a sharp tapered stroke. Move the seam
    # to the middle of the image and compare the same samples, not adjacent ones.
    shifted,_=renderer.render(scene,15444,300,0,seconds=60,overrides={'directionDrive':0.5,'attraction':1,'attractorPosition':0,'angleOffset':0.5})
    assert np.abs(seam.astype(int)-np.roll(shifted,7722,axis=1).astype(int)).max()<=3
    # Isolate the gravity weave: a broad set of curved filaments within the LED
    # band, not an edge marker. Its light is also static until an event arrives.
    for position in [0.25,0.81]:
        fixed={'coverage':0,'attractorPosition':position,'attraction':0.18}
        marker,_=renderer.render(scene,4096,300,0,seconds=1,overrides=fixed)
        later,_=renderer.render(scene,4096,300,0,seconds=9,overrides=fixed)
        assert np.array_equal(marker,later),'Gravity field must not breathe by itself'
        for image in [marker,later]:
            energy=image[:,:,:3].max(axis=2).astype(float)
            columns=energy.sum(axis=0)
            assert abs(np.dot(columns,np.arange(4096)+0.5)/columns.sum()/4096-position)<0.002
            ys,xs=np.where(energy>16)
            assert len(xs)>0 and xs.max()-xs.min()>150,'Field must read as an arc, not a dot'
            assert ys.min()>10 and ys.max()<290,'Gravity weave must stay inside the LED band'
            assert abs(ys.mean()/300-0.5)<0.01,'Field must occupy the band rather than its outer edge'
        flipped,_=renderer.render(scene,4096,300,0,seconds=1,overrides={**fixed,'flipU':1,'flipV':1})
        assert np.abs(marker.astype(int)-flipped[::-1,::-1].astype(int)).max()<=3
        stronger,_=renderer.render(scene,4096,300,0,seconds=1,overrides={**fixed,'attraction':1})
        assert stronger[:,:,0].sum()>marker[:,:,0].sum()*1.4,'Gravity must brighten the local field'
        absent,_=renderer.render(scene,4096,300,0,seconds=1,overrides={**fixed,'attraction':0})
        assert not absent[:,:,:3].any(),'Zero gravity must remove the field'
    print('PASS: static gravity weave inside LED band, OSC coordinates, U/V flips and strength')
    print('PASS Pulse Orbit: quiet current without automatic pulses, trigger acceleration then slow flow, four accents in 4K packing, blanking, five controls, red/white glow and seam',flush=True)
    return dict(scene=scene['id'],packingMaxByteError=max(errors),passed=True)

if __name__=='__main__':
    validate(MetalRenderer(),next(s for s in MANIFEST['scenes'] if s['id']=='09_pulse_orbit'))

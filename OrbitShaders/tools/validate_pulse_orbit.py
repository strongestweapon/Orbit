"""Exercise the native shader with the same Swift physics used by the application."""
import numpy as np
from render_metal import MetalRenderer, MANIFEST

def validate(renderer, scene):
    packed,_=renderer.render(scene,3840,2160,2,seconds=6)
    strip,_=renderer.render(scene,15444,300,0,seconds=6)
    assert np.all(packed[:,:,3]==255)
    assert not packed[1500:,:,:3].any() and not packed[:1500,3564:,:3].any()
    assert not packed[1200:1500,1188:,:3].any()
    errors=[]
    for row in range(5):
        width=3564 if row<4 else 1188
        expected=strip[:,row*3564:row*3564+width,:3].astype(int)
        actual=packed[row*300:(row+1)*300,:width,:3].astype(int)
        errors.append(int(np.abs(expected-actual).max()))
    assert max(errors)<=2, errors
    # Brightness envelopes vary; hue must remain red / white / red at every pixel.
    for band in range(3):
        rgb=strip[band*100:(band+1)*100,:,:3]
        assert rgb[:,:,0].max()>128,(band,'missing pulse')
        if band==1:
            assert np.array_equal(rgb[:,:,0],rgb[:,:,1]) and np.array_equal(rgb[:,:,0],rgb[:,:,2])
        else:
            assert not rgb[:,:,1:].any()
    # Recoloring a track must not recolor or move either neighboring track.
    for key,band in [('innerHue',2),('middleHue',1),('outerHue',0)]:
        replacement=0 if key=='middleHue' else 1
        recolored,_=renderer.render(scene,15444,300,0,seconds=6,overrides={key:replacement})
        for other in range(3):
            region=slice(other*100,(other+1)*100)
            if other==band:
                assert np.any(strip[region]!=recolored[region])
            else:
                assert np.array_equal(strip[region],recolored[region]),(key,'changed another track')
    # Broad sweeps must alternate with quieter packets. Constant occupancy was
    # the previous failure: it looked like rotating UI arcs instead of emitted light.
    energy=[];coverage=[]
    for seconds in [0,1,2,3,4,6,8,10,12,15,18,24]:
        frame,_=renderer.render(scene,4096,300,0,seconds=seconds)
        light=frame[:,:,:3].max(axis=2)
        lit_frame=light>64
        energy.append(light.mean())
        coverage.append([lit_frame[b*100:(b+1)*100].any(axis=0).mean() for b in range(3)])
    assert max(energy)>min(energy)*2, 'Missing buildup/release in light output'
    assert np.mean(coverage)>0.20 and np.all(np.max(coverage,axis=0)>0.45), 'Missing broad sweeps'
    frozen={'directionDrive':0.5,'attraction':0,'rhythmAmount':0}
    a,_=renderer.render(scene,2048,120,0,seconds=3,overrides=frozen)
    b,_=renderer.render(scene,2048,120,0,seconds=8,overrides=frozen)
    assert np.array_equal(a,b), 'Zero drive and rhythm must hold still'
    a,_=renderer.render(scene,2048,120,0,seconds=3,overrides={**frozen,'rhythmAmount':1})
    b,_=renderer.render(scene,2048,120,0,seconds=8,overrides={**frozen,'rhythmAmount':1})
    assert np.abs(a.astype(float)-b.astype(float)).mean()>1, 'Emission must evolve independently of position'
    lit=(strip[:,:,:3].max(axis=(1,2))>0).astype(int)
    assert np.count_nonzero(np.diff(lit)==1)==3, 'Exactly three crisp tracks'
    reverse,_=renderer.render(scene,15444,300,0,seconds=6,overrides={'flipV':1})
    assert np.abs(strip.astype(int)-reverse[::-1].astype(int)).max()<=2
    black,_=renderer.render(scene,1024,96,0,seconds=6,overrides={'brightness':0})
    assert not black[:,:,:3].any()
    for control in scene['parameters']:
        # Position wraps: 0 and 1 are intentionally the same twelve-o'clock angle.
        hi=0.5 if control['id'] in ['attractorPosition','innerHue','middleHue','outerHue'] else 1
        active={'attraction':0.8} if control['id']=='attractorPosition' else {}
        a,_=renderer.render(scene,2048,120,0,seconds=8,overrides={**active,control['id']:0})
        b,_=renderer.render(scene,2048,120,0,seconds=8,overrides={**active,control['id']:hi})
        assert np.abs(a.astype(float)-b.astype(float)).mean()>0.05, control['id']
    a,_=renderer.render(scene,2048,120,0,seconds=0)
    b,_=renderer.render(scene,2048,120,0,seconds=6)
    assert np.abs(a.astype(float)-b.astype(float)).mean()>0.25
    # Put an arc at U=0: both ends of the strip must join without a seam.
    seam,_=renderer.render(scene,15444,300,0,seconds=60,
                          overrides={'directionDrive':0.5,'attraction':1,'attractorPosition':0})
    assert seam[:,0,:3].max()>128 and np.abs(seam[:,0,:3].astype(int)-seam[:,-1,:3].astype(int)).max()<=2
    print('PASS Pulse Orbit: 4K packing, blanking, red/white tracks, independent recoloring, buildup/release, broad sweeps, independent emission, radial flip, fourteen controls, animation, closing seam',flush=True)
    return dict(scene=scene['id'],packingMaxByteError=max(errors),passed=True)

if __name__=='__main__':
    validate(MetalRenderer(),next(s for s in MANIFEST['scenes'] if s['id']=='09_pulse_orbit'))

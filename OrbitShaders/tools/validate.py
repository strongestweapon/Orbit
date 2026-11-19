#!/usr/bin/env python3
"""GPU checks for packing, blanking, orientation, animation and shader parameters."""
import ctypes, json, re
import numpy as np
import objc
from render_metal import ROOT, MANIFEST, MetalRenderer

def validate_isf():
    # Use the system OpenGL compiler only to validate the exported GLSL syntax.
    # The native application and the render tests use Metal, not OpenGL.
    gl=ctypes.CDLL('/System/Library/Frameworks/OpenGL.framework/OpenGL')
    ptr=ctypes.c_void_p;integer=ctypes.c_int;uint=ctypes.c_uint
    gl.CGLChoosePixelFormat.argtypes=[ctypes.POINTER(integer),ctypes.POINTER(ptr),ctypes.POINTER(integer)]
    gl.CGLCreateContext.argtypes=[ptr,ptr,ctypes.POINTER(ptr)];gl.CGLSetCurrentContext.argtypes=[ptr]
    gl.CGLDestroyPixelFormat.argtypes=[ptr];gl.CGLDestroyContext.argtypes=[ptr]
    attrs=(integer*4)(99,0x3200,73,0);fmt=ptr();count=integer();ctx=ptr()
    if gl.CGLChoosePixelFormat(attrs,ctypes.byref(fmt),ctypes.byref(count))!=0: raise RuntimeError('CGL pixel format failed')
    if gl.CGLCreateContext(fmt,None,ctypes.byref(ctx))!=0: raise RuntimeError('CGL context failed')
    gl.CGLSetCurrentContext(ctx);gl.CGLDestroyPixelFormat(fmt)
    gl.glCreateShader.argtypes=[uint];gl.glCreateShader.restype=uint
    gl.glShaderSource.argtypes=[uint,integer,ctypes.POINTER(ctypes.c_char_p),ptr]
    gl.glCompileShader.argtypes=[uint];gl.glGetShaderiv.argtypes=[uint,uint,ctypes.POINTER(integer)]
    gl.glGetShaderInfoLog.argtypes=[uint,integer,ctypes.POINTER(integer),ctypes.c_char_p]
    gl.glDeleteShader.argtypes=[uint]
    results=[]
    try:
        for scene in MANIFEST['scenes']:
            text=(ROOT/scene['isf']).read_text();match=re.match(r'/\*(.*?)\*/',text,re.S)
            meta=json.loads(match.group(1));assert meta['ISFVSN']=='2.0'
            declarations=['#version 150','uniform float TIME;','uniform vec2 RENDERSIZE;',
                          'in vec2 isf_FragNormCoord;','out vec4 orbitOutput;']
            types={'float':'float','long':'int','bool':'bool'}
            for item in meta['INPUTS']:
                assert item['TYPE'] in types
                declarations.append('uniform '+types[item['TYPE']]+' '+item['NAME']+';')
            source=('\n'.join(declarations)+'\n'+text[match.end():].replace('gl_FragColor','orbitOutput')).encode()
            sid=gl.glCreateShader(0x8B30);s=ctypes.c_char_p(source)
            gl.glShaderSource(sid,1,ctypes.byref(s),None);gl.glCompileShader(sid)
            status=integer();gl.glGetShaderiv(sid,0x8B81,ctypes.byref(status))
            if not status.value:
                log=ctypes.create_string_buffer(16384);gl.glGetShaderInfoLog(sid,16384,None,log)
                raise AssertionError(scene['id']+': '+log.value.decode())
            gl.glDeleteShader(sid);results.append(scene['id'])
    finally:
        gl.CGLSetCurrentContext(None);gl.CGLDestroyContext(ctx)
    return results

def validate_radial_patterns(renderer, scene):
    reference,_=renderer.render(scene,3840,2160,2,overrides={'testPattern':0})
    colors=[reference[row*300+75,100,:3] for row in range(5)]
    assert len({tuple(color) for color in colors})==5, 'Each segment must have a distinct color'
    for pattern in (2,10,11):
        packed,_=renderer.render(scene,3840,2160,2,overrides={'testPattern':pattern})
        flipped,_=renderer.render(scene,3840,2160,2,overrides={'testPattern':pattern,'flipV':1})
        for row in range(5):
            width=3564 if row<4 else 1188
            tile=packed[row*300:(row+1)*300,:width,:3]
            # Both halves retain the original segment color; only isolated halves turn black.
            assert np.array_equal(tile[75,100], colors[row] if pattern!=10 else [0,0,0])
            assert np.array_equal(tile[225,100], colors[row] if pattern!=11 else [0,0,0])
            assert np.all(tile[:24]==([0,0,255] if pattern!=10 else [0,0,0])), 'Drawing: top edge must be 24 px outer blue'
            assert np.all(tile[276:]==([255,0,0] if pattern!=11 else [0,0,0])), 'Drawing: bottom edge must be 24 px inner red'
            if pattern!=10: assert np.all(tile[24]==colors[row]), 'Outer band is too thick'
            if pattern!=11: assert np.all(tile[275]==colors[row]), 'Inner band is too thick'
            if pattern==10: assert not tile[:150].any(), 'Inner-only leaks into outer/top half'
            if pattern==11: assert not tile[150:].any(), 'Outer-only leaks into inner/bottom half'
            # Read the seven digit segments from rendered pixels, independently of shader code.
            digits=[(0,1,1,0,0,0,0),(1,1,0,1,1,0,1),(1,1,1,1,0,0,1),
                    (0,1,1,0,0,1,1),(1,0,1,1,0,1,1)]
            points=([(0,-81),(39,-40),(39,40),(0,81),(-39,40),(-39,-40),(0,0)] if pattern==2
                    else [(0,-40),(20,-20),(20,20),(0,40),(-20,20),(-20,-20),(0,0)])
            # Every 1188-pixel module has its row number; no direction lettering remains.
            for module in range(width//1188):
                if pattern==2:
                    assert np.all(tile[24:56]==colors[row]), 'Unexpected lettering above number'
                    assert np.all(tile[244:276]==colors[row]), 'Unexpected lettering below number'
                for center_y in ([150] if pattern==2 else [225] if pattern==10 else [75]):
                    center_x=594
                    segments=tuple(int(np.all(tile[center_y+dy,module*1188+center_x+dx]<12)) for dx,dy in points)
                    assert segments==digits[row], f'Wrong segment number at row {row+1}, module {module+1}: {segments}'
            reverse=flipped[row*300:(row+1)*300,:width,:3]
            assert np.abs(reverse.astype(int)-tile[::-1].astype(int)).max()<=2, 'Radial flip mismatch'
        assert not packed[1500:,:,:3].any() and not packed[:1500,3564:,:3].any()
        ring,_=renderer.render(scene,800,800,1,overrides={'testPattern':pattern})
        y,x=np.mgrid[:800,:800]; radius=np.hypot(x+.5-400,y+.5-400)
        outer=800*.34722222; inner=outer*(1-scene['defaults']['ringWidth']); middle=(inner+outer)/2
        if pattern==10: assert not ring[radius>middle,:3].any(), 'IN is not inside on ring preview'
        if pattern==11: assert not ring[radius<middle,:3].any(), 'OUT is not outside on ring preview'
    print('PASS five colors, upright numbers, 24 px outer/top blue and inner/bottom red, isolated halves and radial flip',flush=True)

def validate_layout_orientation(renderer, scene):
    # Independent drawing convention: source Y increases from outer radius to inner.
    # Read asymmetric glyphs around the physical ring, not through orbitCoordinates.
    ring,_=renderer.render(scene,2000,2000,1,overrides={'testPattern':0})
    outer=2000*.34722222; inner=outer*(1-scene['defaults']['ringWidth'])
    digits=[(0,1,1,0,0,0,0),(1,1,0,1,1,0,1),(1,1,1,1,0,0,1),
            (0,1,1,0,0,1,1),(1,0,1,1,0,1,1)]
    points=[(0,-81),(39,-40),(39,40),(0,81),(-39,40),(-39,-40),(0,0)]
    for row in range(5):
        span=3564 if row<4 else 1188
        center=row*3564+span/2
        observed=[]
        for dx,dy in points:
            theta=(center+dx)/15444*2*np.pi
            radius=outer-(150+dy)/300*(outer-inner)
            x=int(1000+np.sin(theta)*radius); y=int(1000-np.cos(theta)*radius)
            observed.append(int(np.max(ring[y,x,:3])<40))
        assert tuple(observed)==digits[row], f'Drawing numeral {row+1} is mirrored on ring: {observed}'
    ring,_=renderer.render(scene,2000,2000,1,overrides={'testPattern':2})
    # At twelve o'clock, the outer band is farther UP; the inner band is toward the center.
    outer_y=int(1000-(outer-0.04*(outer-inner)))
    inner_y=int(1000-(inner+0.04*(outer-inner)))
    assert np.array_equal(ring[outer_y,1000,:3],[0,0,255])
    assert np.array_equal(ring[inner_y,1000,:3],[255,0,0])
    corona=next(s for s in MANIFEST['scenes'] if s['id']=='04_electric_corona')
    low,_=renderer.render(corona,15444,300,0,seconds=18,overrides={'rootGlow':0})
    high,_=renderer.render(corona,15444,300,0,seconds=18,overrides={'rootGlow':2})
    delta=np.maximum(high[:,:,:3].astype(float)-low[:,:,:3],0)
    assert delta[150:].sum()/delta.sum()>.98, 'Corona inner glow must land in bottom/inner half of source'
    print('PASS supplied layout: clockwise 1–5, upright ring glyphs, physical radial bands and corona inner glow',flush=True)

def main():
    renderer=MetalRenderer();results=[]
    options=objc.lookUpClass('MTLCompileOptions').alloc().init();options.setFastMathEnabled_(False)
    combined='\n'.join(p.read_text() for p in sorted((ROOT/'metal').glob('*.metal')))
    library=renderer.device.newLibraryWithSource_options_error_(combined,options,None)
    assert library is not None,'Combined Metal library failed'
    for scene in MANIFEST['scenes']:
        assert library.newFunctionWithName_(scene['fragmentFunction']) is not None
        packed,_=renderer.render(scene,3840,2160,2,seconds=3)
        strip,_=renderer.render(scene,15444,300,0,seconds=3)
        assert np.all(packed[:,:,3]==255),'Output alpha must be opaque'
        assert not packed[1500:,:,:3].any(),'Bottom blanking'
        assert not packed[:1500,3564:,:3].any(),'Right blanking'
        assert not packed[1200:1500,1188:,:3].any(),'Fifth-row blanking'
        errors=[]
        for row in range(5):
            width=3564 if row<4 else 1188
            expected=strip[:,row*3564:row*3564+width,:3]
            actual=packed[row*300:(row+1)*300,:width,:3]
            delta=np.abs(expected.astype(int)-actual.astype(int))
            errors.append(int(delta.max()))
            assert delta.max()<=2,(scene['id'],'packing mismatch',delta.max())
        black,_=renderer.render(scene,320,180,1,overrides={'brightness':0})
        assert not black[:,:,:3].any(),'Brightness zero'
        a,_=renderer.render(scene,1024,64,0,seconds=0)
        flip,_=renderer.render(scene,1024,64,0,seconds=0,overrides={'flipV':1})
        assert np.max(np.abs(a[::-1].astype(int)-flip.astype(int)))<=2,'Radial flip'
        if not scene['testScene']:
            b,_=renderer.render(scene,1024,64,0,seconds=4)
            assert np.abs(a.astype(int)-b.astype(int)).mean()>0.25,'Animation is static'
            for field in ['hueShift','coverage','gapSoftness','gapMotion','fragmentation']:
                active = {'coverage':0.6} if field in ['gapSoftness','gapMotion','fragmentation'] else {}
                lo,_=renderer.render(scene,256,64,0,overrides={**active,field:0})
                hi,_=renderer.render(scene,256,64,0,overrides={**active,field:0.5 if field=='hueShift' else 1})
                assert np.any(lo!=hi),(scene['id'],field,'has no effect')
            for control in scene['parameters']:
                lo,_=renderer.render(scene,1024,96,0,seconds=18,overrides={control['id']:control['minimum']})
                hi,_=renderer.render(scene,1024,96,0,seconds=18,overrides={control['id']:control['maximum']})
                difference=float(np.abs(lo.astype(float)-hi.astype(float)).mean())
                assert difference>0.05,(scene['id'],control['id'],'no meaningful rendered effect',difference)
            off,_=renderer.render(scene,1024,64,0,overrides={'coverage':0})
            assert not off[:,:,:3].any(),'Coverage zero must remove all light'
            open_arc,_=renderer.render(scene,2048,64,0,seconds=0,overrides={'coverage':0.60,'fragmentation':0})
            dark_columns=np.max(open_arc[:,:,:3],axis=(0,2))==0
            assert 0.2 < dark_columns.mean() < 0.6,(scene['id'],'missing black gap')
            moved,_=renderer.render(scene,2048,64,0,seconds=12,overrides={'coverage':0.60,'fragmentation':0,'gapMotion':1})
            new_dark=np.max(moved[:,:,:3],axis=(0,2))==0
            assert np.mean(dark_columns!=new_dark)>0.15,(scene['id'],'gap does not move')
            # The closing edge is sampled at the same continuous coordinates, not adjacent pixels.
            source=(ROOT/scene['metal']).read_text();namespace='OrbitScene'+str(MANIFEST['scenes'].index(scene)+1)
            source+=f'''
kernel void orbit_seam_test(device float4* out [[buffer(0)]],
constant {namespace}::OrbitParams& p [[buffer(1)]], uint i [[thread_position_in_grid]]) {{
    if(i>=32) return;
    float v=(float(i/2)+0.5)/16.0;
    float2 uv=float2(float(i%2),v);
    out[i]=float4({namespace}::orbitShade(uv,p)*{namespace}::orbitPresence(uv,p),1);
}}
'''
            lib=renderer.device.newLibraryWithSource_options_error_(source,options,None)
            pipeline=renderer.device.newComputePipelineStateWithFunction_error_(lib.newFunctionWithName_('orbit_seam_test'),None)
            out=renderer.device.newBufferWithLength_options_(32*16,0)
            cmd=renderer.queue.commandBuffer();enc=cmd.computeCommandEncoder();enc.setComputePipelineState_(pipeline)
            enc.setBuffer_offset_atIndex_(out,0,0);enc.setBuffer_offset_atIndex_(renderer.uniforms,0,1)
            enc.dispatchThreadgroups_threadsPerThreadgroup_((1,1,1),(32,1,1));enc.endEncoding();cmd.commit();cmd.waitUntilCompleted()
            assert cmd.status()==4
            values=np.frombuffer(ctypes.string_at(out.contents(),512),dtype='<f4').reshape(16,2,4)
            assert np.isfinite(values).all()
            seam=float(np.max(np.abs(values[:,0]-values[:,1])))
            assert seam<0.003,(scene['id'],'closing seam',seam)
        else: seam=None
        results.append({'scene':scene['id'],'packingMaxByteError':max(errors),'seamMaxFloatError':seam,'passed':True})
        print('PASS',scene['id'],flush=True)
    calibration=next(scene for scene in MANIFEST['scenes'] if scene['testScene'])
    pattern_count=len(MANIFEST['testPatterns'])
    for pattern in range(pattern_count):
        img,_=renderer.render(calibration,3840,2160,2,overrides={'testPattern':pattern})
        assert not img[1200:1500,1188:,:3].any()
        if pattern==5: assert np.all(img[:1200,:3564,:3]==255)
        if pattern==6: assert not img[:,:,:3].any()
        if pattern==9: assert set(np.unique(img[:1200,:3564,:3]))=={0,255}
    validate_radial_patterns(renderer,calibration)
    validate_layout_orientation(renderer,calibration)
    isf=validate_isf()
    report={'device':str(renderer.device.name()),'metalFastMath':False,'metal':results,
            'calibrationPatternsPassed':pattern_count,'isfGLSLCompilePassed':isf,
            'milluminApplicationLoadTested':False,'hdmiOutputTested':False}
    (ROOT/'previews/validation.json').write_text(json.dumps(report,indent=2)+'\n')
    print(f'PASS {pattern_count} calibration patterns and {len(isf)} ISF GLSL compiles',flush=True)

if __name__=='__main__':main()

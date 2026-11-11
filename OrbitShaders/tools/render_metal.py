#!/usr/bin/env python3
"""Render the actual Metal kernels on macOS; no Xcode command-line compiler required.
Requires PyObjC (objc, Foundation), numpy and Pillow. Not an application runtime.
"""
import argparse, ctypes, json, statistics, struct, subprocess, time
from pathlib import Path
import objc
import Foundation
import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT=Path(__file__).resolve().parents[1]
MANIFEST=json.loads((ROOT/'config/scenes.json').read_text())

class MetalRenderer:
    def __init__(self):
        namespace={}
        bundle=objc.loadBundle('Metal',namespace,bundle_path='/System/Library/Frameworks/Metal.framework')
        objc.loadBundleFunctions(bundle,namespace,[('MTLCreateSystemDefaultDevice',b'@')])
        self.device=namespace['MTLCreateSystemDefaultDevice']()
        if self.device is None: raise RuntimeError('No Metal device available; run on a Mac with GPU access.')
        self.queue=self.device.newCommandQueue()
        self.buffers={}
        self.pipelines={}
        self.libraries=[]
        self.uniforms=self.device.newBufferWithLength_options_(MANIFEST['uniformBuffer']['sizeBytes'],0)

    def pipeline(self,scene):
        sid=scene['id']
        if sid not in self.pipelines:
            source=(ROOT/scene['metal']).read_text()
            # PyObjC runtime dispatch works without the separate pyobjc-framework-Metal package.
            options=objc.lookUpClass('MTLCompileOptions').alloc().init()
            options.setFastMathEnabled_(False)
            library=self.device.newLibraryWithSource_options_error_(source,options,None)
            if library is None: raise RuntimeError('Metal compilation failed for '+sid)
            fn=library.newFunctionWithName_(scene['computeFunction'])
            pipeline=self.device.newComputePipelineStateWithFunction_error_(fn,None)
            if pipeline is None: raise RuntimeError('Metal compute pipeline failed for '+sid)
            self.libraries.append(library)
            self.pipelines[sid]=pipeline
        return self.pipelines[sid]

    def render(self,scene,width=1280,height=720,view=1,seconds=4.0,overrides=None):
        params=dict(scene['defaults'])
        params.update(outputWidth=width,outputHeight=height,viewMode=view,
                      phaseTime=seconds*scene['defaultClockSpeed'])
        if overrides: params.update(overrides)
        for control in scene.get('parameters',[]):
            params[control['uniform']]=params[control['id']]
        raw=struct.pack('<'+str(len(MANIFEST['uniformBuffer']['fields']))+'f',*(params[k] for k in MANIFEST['uniformBuffer']['fields']))
        ctypes.memmove(self.uniforms.contents(),raw,len(raw))
        size=width*height*4
        if size not in self.buffers: self.buffers[size]=self.device.newBufferWithLength_options_(size,0)
        output=self.buffers[size]
        cmd=self.queue.commandBuffer();enc=cmd.computeCommandEncoder()
        enc.setComputePipelineState_(self.pipeline(scene))
        enc.setBuffer_offset_atIndex_(output,0,0);enc.setBuffer_offset_atIndex_(self.uniforms,0,1)
        enc.dispatchThreadgroups_threadsPerThreadgroup_(((width+15)//16,(height+7)//8,1),(16,8,1))
        enc.endEncoding();cmd.commit();cmd.waitUntilCompleted()
        if cmd.status()!=4: raise RuntimeError(str(cmd.error()))
        pixels=np.frombuffer(ctypes.string_at(output.contents(),size),dtype=np.uint8).reshape(height,width,4).copy()
        ms=(cmd.GPUEndTime()-cmd.GPUStartTime())*1000
        return pixels,ms

def contact_sheet(renderer,output):
    sheet=Image.new('RGB',(1440,((len(MANIFEST['scenes'])+1)//2)*300),'#101217')
    font=ImageFont.truetype('/System/Library/Fonts/Menlo.ttc',18)
    small=ImageFont.truetype('/System/Library/Fonts/Menlo.ttc',13)
    draw=ImageDraw.Draw(sheet)
    for i,scene in enumerate(MANIFEST['scenes']):
        pixels,_=renderer.render(scene,720,405,seconds=6)
        x=(i%2)*720;y=(i//2)*300
        image=Image.fromarray(pixels,'RGBA').convert('RGB').resize((512,288))
        sheet.paste(image,(x+104,y))
        draw.text((x+22,y+259),scene['name'],font=font,fill='#eceef5')
        ref=scene['referenceSeconds']
        text=f'Reference {ref[0]}-{ref[1]}s' if ref else ('10 calibration patterns' if scene['testScene'] else 'Provided still reference')
        draw.text((x+22,y+283),text,font=small,fill='#aeb4c3')
    sheet.save(output)

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--scene',default='all');p.add_argument('--width',type=int,default=1280)
    p.add_argument('--height',type=int,default=720);p.add_argument('--view',type=int,default=1,choices=[0,1,2])
    p.add_argument('--seconds',type=float,default=6);p.add_argument('--video',action='store_true')
    p.add_argument('--fps',type=int,default=30);p.add_argument('--duration',type=float,default=4)
    p.add_argument('--benchmark',action='store_true');p.add_argument('--test-pattern',type=int,default=0)
    args=p.parse_args();renderer=MetalRenderer();print('Device:',renderer.device.name(),flush=True)
    scenes=[s for s in MANIFEST['scenes'] if args.scene=='all' or s['id']==args.scene]
    if not scenes: p.error('Unknown scene')
    timings={}
    for scene in scenes:
        pixels,ms=renderer.render(scene,args.width,args.height,args.view,args.seconds,{'testPattern':args.test_pattern})
        out=ROOT/'previews'/f'{scene["id"]}.png'
        Image.fromarray(pixels,'RGBA').save(out)
        print(scene['id'],'compiled/rendered',round(ms,2),'ms',flush=True)
        if args.benchmark:
            values=[]
            for i in range(24):
                _,gpu=renderer.render(scene,3840,2160,2,seconds=i/60)
                if i>=4: values.append(gpu)
            timings[scene['id']]={'medianGpuMs':statistics.median(values),'maxGpuMs':max(values),
                                  'samples':len(values),'canvas':[3840,2160]}
        if args.video:
            dest=ROOT/'previews'/f'{scene["id"]}.mp4'
            proc=subprocess.Popen(['ffmpeg','-hide_banner','-loglevel','error','-y','-f','rawvideo',
                '-pixel_format','rgba','-video_size',f'{args.width}x{args.height}','-framerate',str(args.fps),
                '-i','-','-an','-c:v','libx264','-preset','fast','-crf','18','-pix_fmt','yuv420p','-movflags','+faststart',str(dest)],stdin=subprocess.PIPE)
            try:
                for i in range(round(args.duration*args.fps)):
                    pixels,_=renderer.render(scene,args.width,args.height,args.view,i/args.fps,{'testPattern':args.test_pattern})
                    proc.stdin.write(pixels.tobytes())
            finally: proc.stdin.close()
            if proc.wait()!=0: raise RuntimeError('ffmpeg encoding failed')
    if args.scene=='all': contact_sheet(renderer,ROOT/'previews/contact-sheet.jpg')
    if timings:
        (ROOT/'previews/benchmark.json').write_text(json.dumps({'device':str(renderer.device.name()),'metalFastMath':False,
            'scope':'compute dispatch only, excludes display, preview compositing, video decoding and Live',
            'results':timings},indent=2)+'\n')

if __name__=='__main__': main()

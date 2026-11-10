#!/usr/bin/env python3
"""Unwrap the actual reference annulus to clockwise strip textures, retaining source frame timing."""
from pathlib import Path
import subprocess,json
import numpy as np
from PIL import Image,ImageDraw,ImageFont
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'OrbitTextures';W,H,FPS=2048,96,24
MANIFEST=json.loads((ROOT/'OrbitShaders/config/scenes.json').read_text())

def coordinates(cx,cy,inner,outer):
    angle=(np.arange(W,dtype=np.float32)+.5)/W*(2*np.pi)
    r=inner+(np.arange(H,dtype=np.float32)[:,None]+.5)/H*(outer-inner)
    x=cx+np.sin(angle)*r;y=cy-np.cos(angle)*r
    xi=x.astype(int);yi=y.astype(int)
    return xi,yi,(x-xi)[...,None].astype(np.float32),(y-yi)[...,None].astype(np.float32)

def unwrap(image,coords):
    xi,yi,fx,fy=coords
    strip=image[yi,xi]*(1-fx)*(1-fy)+image[yi,xi+1]*fx*(1-fy)+image[yi+1,xi]*(1-fx)*fy+image[yi+1,xi+1]*fx*fy
    return np.round(strip).clip(0,255).astype(np.uint8)

def main():
    entries={};coords=coordinates(640,360,218,250)
    for scene in MANIFEST['scenes']:
        sid=scene['id'];rng=scene['referenceSeconds']
        if rng:
            start,end=rng[0]+1,rng[1]-1;duration=end-start;frames=round(duration*FPS)
            output=OUT/'textures'/f'{sid}.mp4'
            reader=subprocess.Popen(['ffmpeg','-loglevel','error','-ss',str(start),'-i',str(ROOT/MANIFEST['referenceVideo']),
                '-t',str(duration),'-vf',f'fps={FPS}','-f','rawvideo','-pix_fmt','rgb24','-'],stdout=subprocess.PIPE)
            encoder=subprocess.Popen(['ffmpeg','-hide_banner','-loglevel','error','-y','-f','rawvideo','-pix_fmt','rgb24',
                '-video_size',f'{W}x{H}','-r',str(FPS),'-i','-','-an','-vf','scale=in_range=pc:out_range=tv:out_color_matrix=bt709',
                '-c:v','libx264','-preset','fast','-crf','14','-g','24','-pix_fmt','yuv420p',
                '-colorspace','bt709','-color_primaries','bt709','-color_trc','bt709','-color_range','tv',
                '-movflags','+faststart',str(output)],stdin=subprocess.PIPE)
            try:
                for i in range(frames):
                    data=reader.stdout.read(1280*720*3)
                    if len(data)!=1280*720*3:raise RuntimeError(f'{sid}: truncated source at frame {i}')
                    strip=unwrap(np.frombuffer(data,np.uint8).reshape(720,1280,3),coords)
                    encoder.stdin.write(strip.tobytes())
                    if i==min(6*FPS,frames-1):Image.fromarray(strip).save(OUT/'review'/f'{sid}.png')
            finally:
                reader.stdout.close();encoder.stdin.close()
            if reader.wait()!=0 or encoder.wait()!=0:raise RuntimeError('ffmpeg failed')
            seed_time={'01_chroma_flow':12,'02_solar_bands':37,'03_aurora_ribbon':56,'04_electric_corona':94,'05_cyan_halo':115}[sid]
            raw=subprocess.check_output(['ffmpeg','-loglevel','error','-ss',str(seed_time),'-i',str(ROOT/MANIFEST['referenceVideo']),'-frames:v','1','-f','rawvideo','-pix_fmt','rgb24','-'])
            seed_name=sid+'-seed.png'
            Image.fromarray(unwrap(np.frombuffer(raw,np.uint8).reshape(720,1280,3),coords)).save(OUT/'textures'/seed_name)
            entries[sid]={'file':output.name,'kind':'video','width':W,'height':H,'fps':FPS,'frames':frames,
                          'duration':duration,'sourceStart':start,'sourceEnd':end,
                          'center':[640,360],'innerRadius':218,'outerRadius':250,'seedFile':seed_name,'seedSourceSeconds':seed_time}
        elif scene.get('referenceImage'):
            name=scene['referenceImage'];image=np.array(Image.open(ROOT/'OrbitApp/Resources'/f'{name}.png').convert('RGB'))
            cy=242 if sid.startswith('07') else 239
            coords_still=coordinates(316,cy,147,169 if sid.startswith('07') else 171)
            strip=unwrap(image,coords_still)
            # Remove the slide's dark background pedestal, preserving the ring's light.
            pedestal=np.median(image[20:40,20:40],axis=(0,1))
            strip=np.round(np.maximum(strip.astype(float)-pedestal,0)*255/(255-pedestal)).clip(0,255).astype(np.uint8)
            output=OUT/'textures'/f'{sid}.png';Image.fromarray(strip).save(output)
            Image.fromarray(strip).save(OUT/'review'/f'{sid}.png')
            entries[sid]={'file':output.name,'kind':'image','width':W,'height':H,'fps':0,'frames':1,'duration':0,
                          'sourceStart':0,'sourceEnd':0,'center':[316,cy],'innerRadius':147,
                          'outerRadius':169 if sid.startswith('07') else 171,'seedFile':output.name}
        else:continue
        print('Extracted',sid,entries[sid]['kind'],flush=True)
    result={'sourceVideo':MANIFEST['referenceVideo'],'u':'clockwise from twelve oclock','v':'inner to outer',
        'encoding':'SDR BT.709 H.264, native 24fps; stills are PNG','textures':entries}
    (OUT/'manifest.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    font=ImageFont.truetype('/System/Library/Fonts/Menlo.ttc',18)
    sheet=Image.new('RGB',(1200,len(entries)*140),'#111318');d=ImageDraw.Draw(sheet)
    for i,(sid,t) in enumerate(entries.items()):
        d.text((14,i*140+8),sid+' / '+t['kind'],font=font,fill='white')
        sheet.paste(Image.open(OUT/'review'/f'{sid}.png').resize((1172,90)),(14,i*140+36))
    sheet.save(OUT/'review/extracted-textures.jpg')
    print('Texture manifest written.',flush=True)

if __name__=='__main__':main()

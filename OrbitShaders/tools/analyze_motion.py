#!/usr/bin/env python3
"""Offline reference analysis only; its images and samples are never loaded by a shader."""
from pathlib import Path
import numpy as np,subprocess,json
from PIL import Image,ImageDraw
root=Path(__file__).resolve().parents[2]
review=root/'OrbitShaders/review';fps=12;w=640;h=360;n=512
u=(np.arange(n)+.5)/n;a=u*2*np.pi
r=np.linspace(109,124,24)[:,None];x=320+np.sin(a)*r;y=180-np.cos(a)*r
xi=x.astype(int);yi=y.astype(int);fx=(x-xi)[...,None];fy=(y-yi)[...,None]
p=subprocess.Popen(['ffmpeg','-loglevel','error','-i',str(root/'KakaoTalk_Video_2026-11-10-09-37-08.mp4'),'-vf',f'scale={w}:{h},fps={fps}','-f','rawvideo','-pix_fmt','rgb24','-'],stdout=subprocess.PIPE)
profiles=[];sampled=[]
while True:
    data=p.stdout.read(w*h*3)
    if len(data)<w*h*3:break
    im=np.frombuffer(data,dtype=np.uint8).reshape(h,w,3)
    strip=(im[yi,xi]*(1-fx)*(1-fy)+im[yi,xi+1]*fx*(1-fy)+im[yi+1,xi]*(1-fx)*fy+im[yi+1,xi+1]*fx*fy)
    profiles.append(strip.mean(0))
    if (len(profiles)-1)%6==0:sampled.append(strip.astype(np.uint8))
p.wait();profiles=np.array(profiles);sampled=np.array(sampled)
np.savez_compressed(review/'source-motion.npz',profiles=profiles.astype(np.float32),strips=sampled,fps=fps)
luma=profiles@[.2126,.7152,.0722]
results={}
for sid,start,end in [('chroma',5,30),('solar',30,50),('aurora',50,75),('corona',75,105),('cyan',105,134)]:
    seg=luma[int((start+1)*fps):int((end-1)*fps)]
    F=np.fft.rfft(seg,axis=1);phase=np.unwrap(np.angle(F[:,1]));t=np.arange(len(seg))/fps
    coeff=np.polyfit(t,phase,1);rotation=-coeff[0]/(2*np.pi)
    residual=np.std(phase-np.polyval(coeff,t));fractions=np.mean(seg<8,axis=1)
    shift=[]; correlations=[];dt=.5;step=6
    for j in range(len(seg)-step):
        a0=seg[j]-seg[j].mean();b0=seg[j+step]-seg[j+step].mean()
        cross=np.fft.irfft(np.conj(np.fft.rfft(a0))*np.fft.rfft(b0),n=n)
        k=int(np.argmax(cross));k=k if k<n/2 else k-n
        shift.append(k/n/dt);correlations.append(float(cross.max()/(np.linalg.norm(a0)*np.linalg.norm(b0)+1e-8)))
    results[sid]={'range':[start,end],'lowFrequencyRotationTurnsPerSec':float(rotation),'periodSeconds':float(1/abs(rotation)),'phaseResidualRadians':float(residual),'medianHalfSecCorrelation':float(np.median(correlations)),'medianLocalTurnsPerSecond':float(np.median(shift)),'darkFractionMean':float(fractions.mean()),'darkFractionRange':[float(fractions.min()),float(fractions.max())]}
    # time down, angle left->right; bright regions trace speed and direction.
    image=Image.fromarray(profiles[int(start*fps):int(end*fps)].astype(np.uint8)).resize((1024,300))
    image.save(review/(sid+'-motion.jpg'))
(review/'source-motion.json').write_text(json.dumps(results,indent=2))
print(json.dumps(results,indent=2))
sheet=Image.new('RGB',(1024,5*340),'#111');d=ImageDraw.Draw(sheet)
for j,key in enumerate(results):
    sheet.paste(Image.open(review/(key+'-motion.jpg')),(0,j*340+30));d.text((10,j*340+8),key+' : time top to bottom; angle clockwise left to right',fill='white')
sheet.save(review/'source-motion-sheet.jpg')

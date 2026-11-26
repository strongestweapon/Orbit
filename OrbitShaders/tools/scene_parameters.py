"""Scene controls: stable public IDs, UI descriptions, ranges and GPU slots."""
def control(id, title, detail, uniform, default, minimum=0, maximum=1, group=0, quick=False, unit="", legacy=None):
    return dict(id=id,title=title,detail=detail,uniform=uniform,defaultValue=default,
                minimum=minimum,maximum=maximum,group=group,quick=quick,unit=unit,legacyKey=legacy)

PARAMETERS = {
 '09_pulse_orbit': [
  control('attraction','중력','빛을 중력점으로 끌어당깁니다. 높을수록 궤적이 좁게 모이고, 겹쳐진 가는 광륜이 선명해집니다. 체류 인원 같은 정규화된 상태를 연결할 수 있습니다.','turbulence',.12,quick=True),
  control('pulseDensity','활동량','짧은 빛 조각을 1개에서 9개까지 드러냅니다. 트리거가 들어오면 잠시 가속·확장합니다.','shape2',.65),
  control('directionDrive','방향 · 추진력','기본 흐름과 트리거 움직임의 방향과 힘입니다. 0은 반시계 우세, 0.5는 추진력 없음, 1은 시계 우세입니다. 가운데 궤도는 반대로 흐릅니다. 짧은 빛은 서로 다른 속도로 이동하고.','density',.78),
  control('inertia','관성','이전 움직임을 유지합니다. 높을수록 가속·감속과 방향 변화가 천천히 일어납니다.','energy',.55),
  control('attractorPosition','중력점 위치','여러 빛줄기가 좁아졌다 펼쳐지는 부분이 중력장입니다. 0/1은 12시, 0.25는 3시입니다. OSC로 위치를 옮기면 광륜과 끌림이 함께 이동합니다. 실제 공간 좌표 데이터가 아닌 연출 위치입니다.','shape0',.15)],
 '01_chroma_flow': [
  control('foldDensity','주름 밀도','높일수록 유체 표면의 주름이 촘촘해집니다.','density',.48,legacy='density',quick=True),
  control('flowDistortion','유체 뒤틀림','표면의 흐름을 국소적으로 구부립니다.','turbulence',.68,legacy='turbulence'),
  control('ridgeWidth','반사선 두께','주름을 따라 생기는 밝은 반사선의 폭입니다.','shape0',1,.2,3,unit='×'),
  control('sheen','반사광 강도','유체 바탕과 별개로 밝은 반사광을 조절합니다.','energy',.52,group=1,legacy='energy'),
  control('poolContrast','명암 대비','유체 안의 어두운 영역과 밝은 영역을 분리합니다.','shape1',1,0,2,group=1,unit='×'),
  control('surfaceDrift','표면 흐름','전체 재생 속도를 유지하면서 표면 질감의 흐름만 바꿉니다.','shape2',1,0,2,group=1,unit='×')],
 '02_solar_bands': [
  control('bandLength','밴드 길이','안쪽에서 바깥쪽으로 뻗는 밴드 길이입니다. 1은 LED 폭 전체입니다.','shape0',1,.1,1,quick=True),
  control('bandDensity','밴드 밀도','링 둘레의 방사형 밴드를 촘촘하게 만듭니다.','density',.62,legacy='density'),
  control('bandBend','밴드 휘어짐','밴드의 국소적인 휘어짐을 조절합니다.','turbulence',.32,legacy='turbulence'),
  control('bandGlow','밴드 발광','밴드의 발광량을 조절합니다.','energy',.62,group=1,legacy='energy'),
  control('bandSharpness','밴드 명암','밴드 사이의 어두운 골을 깊게 만듭니다.','shape1',1,.25,3,group=1,unit='×'),
  control('colorSpread','색 띠 간격','안쪽의 주황색에서 바깥쪽 색으로 변하는 간격입니다.','shape2',1,0,2,group=1,unit='×')],
 '03_aurora_ribbon': [
  control('ribbonWidth','리본 폭','LED 안쪽을 기준으로 리본의 방사 방향 폭을 조절합니다.','shape0',1,.15,1,quick=True),
  control('dustDensity','미세 입자 밀도','리본 표면의 미세한 입자 수를 조절합니다.','density',.4,legacy='density'),
  control('cloudScale','구름결 밀도','흐르는 구름결을 크거나 촘촘하게 만듭니다.','turbulence',.4,legacy='turbulence'),
  control('edgeGlow','테두리 발광','리본 안쪽과 바깥쪽의 밝은 가장자리만 조절합니다.','energy',.62,group=1,legacy='energy'),
  control('sparkleStrength','입자 반짝임','리본 바탕과 별개로 미세 입자의 빛을 조절합니다.','shape1',1,0,2,group=1,unit='×'),
  control('warmLobes','양옆의 금빛','좌우에 머무르는 따뜻한 금빛 영역의 강도입니다.','shape2',1,0,1,group=1)],
 '04_electric_corona': [
  control('filamentLength','코로나 길이','안쪽에서 바깥쪽으로 뻗는 전기 필라멘트의 길이입니다.','shape0',1,.1,1.5,quick=True,unit='×'),
  control('filamentDensity','필라멘트 밀도','방사형 전기 가닥을 촘촘하게 만듭니다.','density',.6,legacy='density'),
  control('filamentBend','필라멘트 휘어짐','전기 가닥이 바깥쪽으로 갈수록 휘는 양입니다.','turbulence',.7,legacy='turbulence'),
  control('dischargeIntensity','방전 강도','바탕과 안쪽 광륜을 유지하며 전기 가닥의 빛을 조절합니다.','energy',.62,group=1,legacy='energy'),
  control('filamentWidth','필라멘트 두께','전기 가닥의 굵기를 조절합니다.','shape1',1,.25,2.5,group=1,unit='×'),
  control('rootGlow','안쪽 광륜','전기 가닥이 시작되는 안쪽 테두리의 발광량입니다.','shape2',1,0,2,group=1,unit='×')],
 '05_cyan_halo': [
  control('beamWidth','밝은 구간 길이','링 둘레에서 청백색으로 밝아지는 구간을 넓힙니다.','shape0',1,.2,2.5,quick=True,unit='×'),
  control('haloWidth','헤일로 폭','LED 안쪽을 기준으로 빛 띠의 방사 방향 폭을 조절합니다.','shape1',1,.1,1),
  control('foldScale','표면 주름 밀도','헤일로 안의 작은 주름을 촘촘하게 만듭니다.','density',.32,legacy='density'),
  control('haloGlow','헤일로 발광','청록색 빛 띠의 발광량을 조절합니다.','energy',.65,group=1,legacy='energy'),
  control('foldDistortion','주름 뒤틀림','밝은 구간과 표면 주름의 국소적인 뒤틀림입니다.','turbulence',.4,group=1,legacy='turbulence'),
  control('acceleration','회전 가속','기본 회전은 유지하고 주기 중 빨라지는 정도만 조절합니다.','shape2',1,0,2,group=1,unit='×')],
 '07_spectral_fragments': [
  control('barLength','바 길이','각 빛 조각의 시작점은 유지하고 방사 방향 끝점을 늘립니다.','shape0',1,.1,1.4,quick=True,unit='×'),
  control('barWidth','바 두께','직선 바와 작은 빛 조각의 둘레 방향 굵기입니다.','shape1',1,.25,4,unit='×'),
  control('fragmentDensity','바 밀도','동시에 켜져 있는 바의 수를 조절합니다.','density',.55,legacy='density'),
  control('fragmentGlow','바 발광','색 띠의 밝기와 별개로 직선 바의 발광량을 조절합니다.','energy',.6,group=1,legacy='energy'),
  control('lifetimeRate','생성·소멸 속도','이동 속도와 별개로 바가 나타나고 사라지는 주기입니다.','shape2',1,.1,3,group=1,unit='×'),
  control('driftVariation','흐름 변동','바를 구부리지 않고 층별 이동과 점멸의 변동을 조절합니다.','turbulence',.45,group=1,legacy='turbulence')],
 '08_golden_drift': [
  control('headWidth','금빛 머리 길이','링 둘레에서 가장 밝은 금빛 머리가 차지하는 길이입니다.','shape0',1,.3,2,quick=True,unit='×'),
  control('particleDensity','입자 밀도','금빛 머리 크기는 유지하고 미세 입자 수를 조절합니다.','density',.45,legacy='density'),
  control('particleSize','입자 크기','반짝이는 금빛 입자 하나의 크기입니다.','shape1',1,.3,3,unit='×'),
  control('headGlow','머리 발광','입자의 밝기와 별개로 금빛 머리의 발광량입니다.','energy',.65,group=1,legacy='energy'),
  control('sparkleStrength','입자 반짝임','금빛 머리를 유지하고 입자의 발광량만 조절합니다.','shape2',1,0,3,group=1,unit='×'),
  control('rippleDepth','물결 굴곡','금빛 머리 내부의 부드러운 물결 변형입니다.','turbulence',.4,group=1,legacy='turbulence')],
}

# Keep the experimental hue IDs stable for saved routes, but select only red/white.
for parameter in PARAMETERS['09_pulse_orbit']:
    if parameter['group'] == 2 or parameter['id'] in ('counterflow','outerReverse'): parameter['isSwitch'] = True

# The public control surface follows each scene's visual complexity. Removed
# 0.3 controls remain available internally so saved values and live routes survive.
PARAMETERS['07_spectral_fragments'].append(
 control('filmMix','색 띠 비중','직선 바를 유지하면서 바탕의 스펙트럼 색 띠만 드러내거나 지웁니다.','shape3',1,0,1))
for controls in PARAMETERS.values():
    for index, parameter in enumerate(controls): parameter['midiCC'] = 40 + index

RETIRED = {
 '01_chroma_flow': {'poolContrast'},
 '02_solar_bands': {'bandBend','bandGlow'},
 '03_aurora_ribbon': {'cloudScale'},
 '05_cyan_halo': {'foldScale','haloGlow','foldDistortion'},
 '08_golden_drift': {'rippleDepth'},
}
COMPATIBILITY_PARAMETERS = {
 sid:[p for p in controls if p['id'] in RETIRED.get(sid,set())]
 for sid,controls in PARAMETERS.items()
}
PARAMETERS = {
 sid:[p for p in controls if p['id'] not in RETIRED.get(sid,set())]
 for sid,controls in PARAMETERS.items()
}

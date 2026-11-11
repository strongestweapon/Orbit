# Orbit

원형 LED 설치물을 위한 macOS 네이티브 영상 앱입니다. SwiftUI와 Metal로 실시간 영상을 생성하고 OSC 센서 값을 씬 파라미터에 연결합니다.

## 기능

- 코드로 생성하는 7개 아트 씬과 LED 테스트 패턴 10종
- 재생·일시정지·속도·밝기·재생 시간 표시
- 원형 미리보기, 펼친 영상, 4K 출력 배치 동시 표시
- OSC UDP 센서 입력 추가 및 파라미터마다 독립적인 입력 매핑·보간
- 파라미터 옆 연결 버튼: 입력 센서와 MIDI CC / OSC 출력을 각각 설정
- Ableton용 가상 MIDI 포트 `Orbit Control`, 제어 출력 전체 시작·중지, 단일 파라미터 학습 신호
- 출력 디스플레이 선택과 실제 출력 프레임에 연동된 빨간 테두리
- 16:9 출력 크기 선택: 화면에 맞춤, HD, FHD, QHD, 4K, 직접 입력
- 외부 모니터 없이 별도 출력 창 사용 및 전체화면 전환
- 씬 연출·센서·매핑·출력 설정 팝업
- 비교용 원본 영상 및 추출 띠 텍스처 재생

기본 영상 소스인 **실시간 생성**은 이미지/영상 텍스처 없이 씬별 코드로 계산합니다. **원본 재생**을 선택하면 번들에 포함된 추출 리소스를 사용합니다. MIDI CC 및 OSC 제어 송신은 구현되어 있으며, Live에서 제어할 대상은 MIDI Map 또는 별도 OSC 수신 장치에 연결합니다. 자동 업데이트는 아직 구현하지 않았습니다.

## 실행

macOS 14 이상을 대상으로 합니다. 저장소에 Xcode 프로젝트와 필수 미디어 리소스가 포함되어 있습니다.

1. `OrbitApp/Orbit.xcodeproj`를 Xcode에서 엽니다.
2. `Orbit` scheme과 `My Mac`을 선택합니다.
3. Run으로 실행합니다. Space로 재생/일시정지를 전환합니다.

터미널 빌드:

```sh
xcodebuild -project OrbitApp/Orbit.xcodeproj -scheme Orbit \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build build
```

Metal 소스는 앱에서 런타임에 컴파일합니다. 별도 Metal Toolchain 다운로드는 이 프로젝트 빌드에 필요하지 않습니다. 프로젝트 설정의 원본은 `OrbitApp/project.yml`이며, 재생성할 때는 XcodeGen으로 `xcodegen generate --spec OrbitApp/project.yml`을 실행합니다.

## 로고

앱 아이콘은 승인된 01번 Light Orbit 디자인입니다. 원본은 `Branding/orbit-icon-master.png`, 생성 프롬프트와 폰트 정보는 `Branding/brand.json`에 있습니다. 시안의 ORBIT 글자는 생성된 레터링이며 특정 폰트를 사용한 결과가 아닙니다. 앱 헤더는 유사한 기하학적 산세리프인 macOS 기본 **Avenir Next Medium**, 17 pt, 자간 4 pt를 사용합니다.

`python3 OrbitApp/Tools/package_icon.py`로 원본의 투명도를 유지하면서 16–1024 px 아이콘을 `OrbitApp/Resources/OrbitAppIcon.icns`로 패키징하고 헤더용 `OrbitLogo.png`를 만듭니다. Finder·Dock·앱 정보 창은 같은 아이콘을 사용합니다.

## 파라미터 입력·출력 매핑

메인 화면 및 **씬 연출**의 각 파라미터 이름 옆 **연결 아이콘**을 누릅니다. 입력과 출력은 서로 독립적으로 켜며, 한 씬에서 여러 파라미터가 동시에 동작합니다. 설정은 씬·영상 소스(실시간 생성/원본 재생)·파라미터별로 저장합니다. 기존 씬당 하나의 매핑도 해당 파라미터로 자동 이전합니다.

- **입력:** 등록된 OSC 센서, 영상 값 최소·최대, 보간 시간을 설정합니다. 최소·최대를 뒤집어 역방향 매핑도 가능합니다. 수신이 90초간 없거나 센서가 삭제되면 설정한 기본값으로 복귀합니다. 센서 제어 중 슬라이더에는 실제 적용값을 표시하고 수동 드래그를 잠급니다.
- **출력:** 센서 또는 수동 조작으로 결정된 실제 영상 값을 MIDI CC 또는 OSC float 하나로 변환합니다. 각 파라미터에 채널·CC 혹은 대상 호스트·포트·OSC 주소, 송신 범위를 따로 지정합니다. 같은 씬에서 출력 주소가 중복되면 충돌 표시와 함께 해당 출력을 중단합니다.
- **제어 출력:** 메인 화면의 스위치로 선택한 씬의 활성 출력들을 함께 켭니다. 재실행 시에는 꺼진 상태로 시작합니다. 제어 처리는 렌더링과 분리된 30 Hz 타이머를 사용하며, 동일 값은 묶어 보내고 2초 간격으로 다시 전송합니다. 테스트 씬에서는 제어 자동 송신을 하지 않습니다.

### Ableton Live 연결

1. Orbit을 실행하고 Live **Settings → Link, Tempo & MIDI**에서 `Orbit Control` **Input의 Remote**를 켭니다.
2. Orbit 파라미터의 **출력** 탭에서 MIDI CC와 채널·CC 번호를 지정하고 **이 파라미터 송신**을 켭니다.
3. **제어 자동 송신을 끈 상태**에서 Live의 MIDI Map을 켜고 연결할 노브를 선택합니다.
4. Orbit에서 **이 파라미터 신호 보내기**를 누릅니다. 이 버튼은 다른 파라미터의 자동 송신을 중지하고 선택한 CC 하나만 보냅니다.
5. Live의 MIDI Map을 종료한 뒤 Orbit의 **제어 출력**을 켭니다. 매핑은 Live Set에 저장합니다.

설정 근거: [Ableton MIDI 매핑](https://help.ableton.com/hc/en-us/articles/360000038859-Making-custom-MIDI-Mappings), [Live MIDI 입출력 설정](https://www.ableton.com/en/manual/routing-and-i-o/).

OSC 출력의 기본 대상은 `127.0.0.1:9001`이며 주소는 `/orbit/<scene>/<parameter>`입니다. Live에서 OSC를 쓸 경우 Max for Live 등 별도 수신 장치가 필요합니다. **UDP 송신 성공은 상대 앱 수신 확인이 아닙니다.** 오디오 재생·스피커 채널 라우팅은 Live가 담당합니다.

매핑 및 실제 전송 검증(두 번째 테스트는 Mac의 CoreMIDI와 localhost UDP를 사용):

```sh
xcrun swiftc OrbitApp/Sources/ParameterRouting.swift OrbitApp/Tests/ParameterRoutingChecks.swift -o /tmp/orbit-parameter-check
/tmp/orbit-parameter-check
xcrun swiftc OrbitApp/Sources/ParameterRouting.swift OrbitApp/Sources/ControlOutput.swift OrbitApp/Tests/ControlOutputChecks.swift -o /tmp/orbit-control-output-check
/tmp/orbit-control-output-check
```

## LED 출력

논리 링은 **15444 × 300**입니다. 기준 캔버스는 3840 × 2160이며 왼쪽 위에 3564 × 300 네 줄과 1188 × 300 한 줄로 배치하고 나머지는 검정으로 출력합니다. 다른 해상도를 선택하면 이 배치 전체를 16:9 비율로 스케일링합니다.

**출력 설정 → 디스플레이 · 크기**에서 모니터와 해상도를 선택합니다. 기본값인 **현재 화면 / 화면에 맞춤**은 외부 모니터 없이 사용 가능합니다. **출력 시작**을 누르면 크기 조절 가능한 별도 창이 열리며, 앱에서 다른 기능을 조작해도 출력 창이 위에 유지됩니다. 창의 **전체화면** 버튼, 녹색 창 버튼 또는 **⌘⇧F**로 해당 모니터의 전체화면을 사용하고, Esc로 창 모드로 돌아옵니다. 창 모드로 돌아온 뒤에도 위에 유지됩니다. **출력 중지** 또는 **⌘.**으로 출력을 종료합니다.

자동 해상도는 창·모니터의 Retina 배율까지 반영합니다. HD·FHD·QHD·4K 또는 직접 입력은 지정한 렌더 해상도를 유지하면서 화면에 맞춰 표시합니다. 직접 입력은 가로 320–7680 px 범위, 16 px 단위이며 세로는 자동 계산합니다. 16:9가 아닌 화면은 검정 여백으로 비율을 유지합니다. 출력 창을 닫으면 출력과 빨간 표시도 꺼집니다.

LED의 1:1 픽셀 테스트는 **4K** 선택, **3840 × 2160 디스플레이의 전체화면**에서 진행합니다. 실제 LED의 방향·구간 순서는 테스트 패턴으로 확인합니다.

## 파일 구성

- `OrbitApp/`: SwiftUI 운영 화면, Metal 렌더러, OSC 수신, 출력 창, 원본 비교 플레이어
- `OrbitShaders/src/`: GLSL 공통 수식과 씬 소스
- `OrbitShaders/metal/`, `OrbitShaders/isf/`: 생성된 Metal / ISF 셰이더
- `OrbitShaders/config/`: 씬·파라미터·매핑 정의
- `OrbitShaders/tools/`: 생성·렌더·검증 도구
- `OrbitTextures/`: 비교용 추출 텍스처와 출처 메타데이터
- `KakaoTalk_Video_2026-11-10-09-37-08.mp4`: 앱의 원본 비교용 영상

세부 좌표와 셰이더 구조는 [셰이더 문서](OrbitShaders/README.md)를 참고하세요. `OrbitHybrid_*` 파일은 이전 실험의 보관 코드이며 현재 앱에서 실행하지 않습니다.

## 셰이더 생성 및 검증

출력 크기·Retina·16:10·울트라와이드·세로 화면의 비율 검증:

```sh
xcrun swiftc OrbitApp/Sources/OutputGeometry.swift OrbitApp/Tests/OutputGeometryChecks.swift -o /tmp/orbit-output-geometry-check
/tmp/orbit-output-geometry-check
python3 OrbitShaders/tools/validate_output_scaling.py
```

```sh
python3 OrbitShaders/tools/build_shaders.py
python3 OrbitShaders/tools/validate.py
python3 OrbitShaders/tools/review_spectral.py
```

검증 도구에는 Mac GPU, Python의 NumPy·Pillow·PyObjC(Foundation)가 필요합니다. 영상 추출/출력에는 FFmpeg가 필요합니다. `render_metal.py`로 생성하는 `previews/`와 분석용 `review/`는 로컬 산출물입니다. 디렉터리를 사용하는 도구 실행 전 필요하면 아래처럼 생성합니다.

```sh
mkdir -p OrbitShaders/previews OrbitShaders/review OrbitTextures/review
```

4K 패킹·검정 여백·밝기·방향 반전·파라미터 반응·링 이음새와 ISF 컴파일을 실제 Mac GPU에서 검증했습니다. HDMI/LED 현장 연결 검증은 별도입니다. 셰이더가 원본 제작 알고리즘이나 동일 프레임을 복원한다는 의미는 아닙니다.

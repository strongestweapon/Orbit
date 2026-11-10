# Orbit

원형 LED 설치물을 위한 macOS 네이티브 영상 앱입니다. SwiftUI와 Metal로 실시간 영상을 생성하고 OSC 센서 값을 씬 파라미터에 연결합니다.

## 기능

- 코드로 생성하는 7개 아트 씬과 LED 테스트 패턴 10종
- 재생·일시정지·속도·밝기·재생 시간 표시
- 원형 미리보기, 펼친 영상, 4K 출력 배치 동시 표시
- OSC UDP 센서 입력 추가 및 씬별 파라미터 매핑·보간
- 출력 디스플레이 선택과 실제 출력 프레임에 연동된 빨간 테두리
- 씬 연출·센서·매핑·출력 설정 팝업
- 비교용 원본 영상 및 추출 띠 텍스처 재생

기본 영상 소스인 **실시간 생성**은 이미지/영상 텍스처 없이 씬별 코드로 계산합니다. **원본 재생**을 선택하면 번들에 포함된 추출 리소스를 사용합니다. Ableton Live 제어 브리지와 자동 업데이트는 아직 구현하지 않았습니다.

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

## LED 출력

논리 링은 **15444 × 300**입니다. 3840 × 2160 화면 왼쪽 위에 3564 × 300 네 줄과 1188 × 300 한 줄로 배치하고 나머지는 검정으로 출력합니다. 출력할 디스플레이를 3840 × 2160으로 설정해야 합니다. 실제 LED의 방향·구간 순서는 테스트 패턴으로 확인합니다.

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

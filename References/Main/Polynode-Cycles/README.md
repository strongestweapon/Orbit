# Pulse Orbit 메인 레퍼런스 — Polynode: Cycles

2026-11-26 사용자가 제공한 아래 영상 네 개를 Pulse Orbit의 **메인 영상 레퍼런스**로 지정했습니다. 움직임·속도 변화·방향·생성 및 소멸 리듬·긴 호와 짧은 빛의 구성을 비교할 때 이 로컬 영상 네 개를 우선 확인합니다.

출처: [Instagram 게시물](https://www.instagram.com/p/DeRU92jDVrC/)

| 저장 파일 | 길이 | 해상도 | 제공된 원본 파일명 |
|---|---:|---:|---|
| [01-polynode-cycles.mp4](01-polynode-cycles.mp4) | 15.09초 | 720 × 900 | Polynode- Cycles has found a new home.Yesterday, EGO, the new exhibition at Light Art Museum Bud.mp4 |
| [02-polynode-cycles.mp4](02-polynode-cycles.mp4) | 14.77초 | 720 × 900 | Polynode- Cycles has found a new home.Yesterday, EGO, the new exhibition at Light Art Museum Bud (1).mp4 |
| [03-polynode-cycles.mp4](03-polynode-cycles.mp4) | 31.18초 | 720 × 900 | Polynode- Cycles has found a new home.Yesterday, EGO, the new exhibition at Light Art Museum Bud (2).mp4 |
| [04-polynode-cycles.mp4](04-polynode-cycles.mp4) | 23.36초 | 720 × 900 | Polynode- Cycles has found a new home.Yesterday, EGO, the new exhibition at Light Art Museum Bud (3).mp4 |

01–04는 원본 파일명 접미사 없음 → (1) → (2) → (3) 순서로 붙인 로컬 관리 번호이며, Instagram 게시물의 순서를 확정한 번호는 아닙니다.

원본을 재인코딩하지 않고 복사했습니다. 각 파일의 SHA-256 일치와 전체 영상 디코딩을 확인했습니다. 상세 정보는 [manifest.json](manifest.json)에 있습니다.

영상은 연출 비교 자료입니다. Orbit의 실시간 생성은 기존처럼 코드 기반이며, 이 파일을 앱 텍스처나 재생 콘텐츠로 자동 편입하지 않습니다. 사용자와 정한 중력 서사·OSC 인과관계·빠른 트리거의 개별 반영도 함께 유지합니다.

## 2026-11-26 구현 비교 기록

네 파일의 전체 구간을 0.25초 간격으로 추출하고, 긴 시간 변화와 세부 이동 구간을 비교했습니다.

- **01:** 붉은 여러 가닥이 함께 추격하고 긴 꼬리를 만듭니다. 주요 묶음이 돌아오는 주기는 관찰상 약 3초입니다.
- **02:** 전반의 긴 흰 호가 약 8초 이후 짧고 성긴 빛으로 수축합니다.
- **03:** 흰 흐름이 길어져 약 24–25초에는 둘레를 크게 채우고, 약 26초부터 다시 짧아집니다.
- **04:** 붉은 빛의 작은 무리는 느리게 이동하고 흰 빛들이 다른 속도로 통과합니다.

실제 설치물의 카메라 노출·반사는 그대로 모사하지 않습니다. 궤적의 길이 대비, 무리의 시차, 속도 차이, 펼쳐짐과 수축을 코드로 해석합니다. 사용자가 점선을 싫어한다고 명시했으므로 짧은 빛도 매끈하게 가늘어지는 연속선으로 표현합니다.

중력 서사와 연속값 5개·트리거 4개는 유지합니다. 중력 위치는 별도 흰 점 대신 띠 내부에서 여러 광선이 모이고 다시 펼쳐지는 광륜으로 표현합니다. 기존 OSC 주소와 입력·출력 동작은 바꾸지 않습니다.

2026-11-26 후속 조정: 짧고 밝은 빛 조각과 띠에 수직인 작은 선들을 함께 사용합니다. 수직선은 불규칙한 무리로 느리게 이동하고, 이동 조각은 기본값에서도 몇 초 사이에 위치가 크게 바뀝니다. 긴 띠는 이벤트 중에도 짧게 제한하고, 기존 5개 연속값·4개 트리거·OSC 주소를 유지합니다.

수직선 최종 동작: 출발·돌파·새 궤도 트리거마다 생성되고 개별 수명 뒤 소멸합니다. 완료는 주변 수직선을 모아 지웁니다. 연속값과 자동 교차는 수직선 생성·소멸에 연결하지 않습니다. 기존 이야기와 파라미터 의미는 유지합니다.

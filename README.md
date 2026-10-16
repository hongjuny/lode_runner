# Lode Runner for macOS

Apple II용 **Lode Runner**의 게임 규칙과 화면 자료를 Swift/AppKit으로 옮긴 macOS 포트다. 원본 역공학 자료는 [`apple2/`](apple2/)에 보존하고, 실행 앱과 테스트는 저장소 루트에서 빌드한다.

이 포트의 우선순위는 **게임 진행의 일치**다. 같은 입력에서 이동, 굴착, 낙하, 금 수집, 경비병 행동, 구덩이 복구, 사망과 레벨 전환이 원본과 같은 순서로 일어나도록 구현했다. Apple II의 메모리 주소 배치나 스피커 회로를 사이클 단위로 에뮬레이션하지는 않는다.

## 빠른 시작

macOS 14 이상과 Xcode의 Swift 도구가 필요하다. [`LodeRunner.xcodeproj`](LodeRunner.xcodeproj)를 열고 **LodeRunner** 스킴을 Build 또는 Run하면 된다. Xcode 빌드 결과는 `Build/LodeRunner.app`이다.

터미널에서도 같은 위치에 앱을 만들 수 있다.

```sh
sh scripts/build-macos-app.sh
open Build/LodeRunner.app
```

첫 화면에서 아무 키나 누르면 시작한다.

| 동작 | 키 |
| --- | --- |
| 이동 | `I J K L`, 방향키, 또는 `W A S D` |
| 왼쪽 / 오른쪽 굴착 | `U` / `O` (`Z` / `X`도 사용 가능) |
| 일시 정지 | Space |
| 게임 오버 뒤 새 게임 | Return |
| 속도 1× / 2× / 3× / 4× | `⌘1` / `⌘2` / `⌘3` / `⌘4` |

굴착 키는 물리 키 위치를 읽으므로 한글 입력기에서도 동작한다. 시작 속도는 1×이며, 초당 24게임 단계로 설정되어 있다. 이는 원본의 `FRAME_PERIOD=6`을 참고한 체감 속도 추정치로, Apple II+의 사이클 속도를 측정한 값은 아니다.

## 구성

| 경로 | 내용 |
| --- | --- |
| [`Sources/LodeRunnerCore/`](Sources/LodeRunnerCore/) | 레벨 해독, 두 보드, 플레이어·경비병·타이머·게임 루프, 스프라이트와 HGR 색상 판정 |
| [`Sources/LodeRunnerMac/`](Sources/LodeRunnerMac/) | AppKit 창, 키 입력, 고정 게임 단계, 화면 출력, 대체 효과음 |
| [`Sources/LevelInspector/`](Sources/LevelInspector/) | 레벨 데이터를 텍스트로 검사하는 명령줄 도구 |
| [`Tests/`](Tests/) · [`fixtures/`](fixtures/) | 게임 규칙 테스트와 원본 6502 실행 캡처 |
| [`tools/`](tools/) | 원본 자료에서 레벨·스프라이트·타이틀 데이터를 추출하고 확인하는 도구 |
| [`apple2/`](apple2/) | 원본 역공학 문서, 6502 어셈블리, 디스크 섹터, 바이너리와 원본 빌드 도구 |
| [`docs/`](docs/) | [메인 로직과 I/O 지도](docs/main_logic_io_map.md), [포팅 계획](docs/porting_plan.md), [원본 실행 기준선](docs/reference_baseline.md) |

## 포팅 원리

### 게임 상태와 실행 순서

원본의 제로페이지에는 플레이어 좌표뿐 아니라 행 포인터, 경비병 작업값, 그리기 인자가 섞여 있다. 포트에서는 오래 유지되는 상태를 `GameState`·`PlayerState`·`GuardState`에 두고, 호출 중에만 필요한 값은 지역 계산으로 분리했다. 원본의 활성 보드와 배경 보드(`$0800`/`$0A00`)는 각각 `activeBoard`와 `backgroundBoard`로 유지한다.

게임 한 단계는 `MOVE_PLAYER`에 해당하는 플레이어 동작에서 시작한다. 이어서 충돌과 사망, 금이 모두 없어졌을 때의 출구 사다리, 레벨 완료, 구덩이·부활 타이머, 경비병 이동을 원본 호출 순서대로 처리한다. 굴착은 입력을 한 번 읽고 여러 단계에 걸쳐 진행하며, 구덩이는 만들어진 같은 게임 단계에서 타이머가 180에서 179로 감소한다. 150레벨을 끝내면 원본 로더처럼 첫 디스크 레벨부터 다시 진행하며 경비병 패턴 오프셋이 증가한다.

### 원본 자료와 화면

150개 레벨은 [`apple2/disk/`](apple2/disk/)의 256바이트 섹터에서 추출했다. 원본 104개 스프라이트는 [`apple2/sprite_data.asm`](apple2/sprite_data.asm)의 비트를 그대로 사용한다. 타이틀은 [`apple2/main.bin`](apple2/main.bin)의 압축 HGR 데이터를 풀어 넣었다. 게임 화면은 28×16칸을 10×11픽셀 스프라이트로 그려 280×192 화면을 만들고, 아래에는 원본 글자 스프라이트로 상태줄을 그린다.

색상은 고정된 RGB 스프라이트 이미지가 아니다. HGR의 비트 패턴에서 인접 비트 `11`을 흰색으로, 떨어진 비트와 바이트의 상위 비트에서 파랑·주황 등의 색을 판정한다. macOS 창은 이 결과를 정수 배율로 확대한다. 원본의 비연속적인 HGR 행 주소, 페이지 전환, NTSC 출력 회로까지 복제하는 방식은 아니다. RGB 값과 원형 화면 전환은 시각적 근사치다.

### 시간과 소리

호스트 화면 갱신과 게임 단계를 분리했다. `⌘1`–`⌘4`는 한 초에 실행하는 게임 단계 수를 바꾸고, 각 단계 안의 규칙과 타이머 순서는 그대로 유지한다. 효과음은 짧은 사각파 대체 음이며 Apple II 스피커 토글과 원본 음표 지연을 재현하지 않는다.

## 검증과 현재 범위

```sh
swift test --scratch-path /tmp/lode-runner-swift-build
python3 tools/capture_reference.py --check
python3 tools/export_levels.py --check
python3 tools/export_sprites.py --check
python3 tools/export_splash.py --check
```

테스트는 150개 레벨 섹터의 왕복 인코딩, 1레벨의 원본 실행 캡처, 플레이어 이동과 굴착, 경비병 패턴, 금 운반, 구덩이·사망·출구 및 150레벨 경계를 다룬다. 원본과 긴 입력열을 여러 레벨에 걸쳐 비교하는 검증은 아직 남아 있다. 원본의 레벨 편집기, 점수 저장, 시연 모드도 macOS 앱에는 없다. 화면 픽셀과 효과음의 하드웨어 단위 일치보다 게임 진행 검증을 우선한다.

## Apple II 원본 자료

[`apple2/`](apple2/)는 [XekriRedmane의 Lode Runner 역공학 저장소](https://github.com/XekriRedmane/lode_runner_reveng)의 소스와 데이터를 옮긴 것이다. 설명이 포함된 원본 문서는 [`apple2/main.pdf`](apple2/main.pdf)와 [`apple2/main.nw`](apple2/main.nw)다. 원본의 어셈블리와 디스크 이미지를 다시 빌드하려면 `dasm`과, PDF 생성에는 TeX Live가 필요하다.

```sh
cd apple2
python3 build.py
# PDF가 필요할 때: pdflatex main.tex 를 두 번 실행
```

원본 프로젝트의 라이선스 표기는 [Creative Commons Attribution-ShareAlike 4.0 International](https://creativecommons.org/licenses/by-sa/4.0/)이다. 원본의 출처를 보존하고 이 포트에도 같은 조건을 적용한다. 게임 이름과 원작에 대한 권리는 각 권리자에게 있다.

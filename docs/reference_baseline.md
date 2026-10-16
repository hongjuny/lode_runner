# 원본 실행 기준선

이 기준선은 두 종류의 자료로 구성된다.

1. `fixtures/reference_levels.json`: 저장된 `apple2/main.bin`/`apple2/golden_source.bin`과 150개 레벨 섹터에서 추출한 **정적 데이터**. `python3 tools/capture_reference.py --check`로 검증한다.
2. `fixtures/runtime/*.json`: 재구성한 디스크 이미지를 Apple II 실행기에서 돌려 얻은 **실행 중 메모리 상태**. 6502 코드의 상태 전이를 비교할 때 사용한다.

`tools/extract_runtime_snapshot.py`는 실행기의 128 KiB RAM 덤프에서 게임 규칙에 필요한 주소를 추출한다. 화면의 HGR 픽셀, CPU 레지스터, 전체 디스크 I/O 기록은 스냅샷에 포함하지 않았다. `capture_pc`는 덤프 직전 실행기가 멈춘 PC이며, 보드/경비병 데이터는 그 순간의 메모리 값이다.

## 원본과 실행 환경

- 소스: 저장된 `apple2/main.bin` SHA-256 `5c9cc551242e08b76cb3a37e89f8bfb6dc02d886b628aab07798833b8708bbb1`
- `apple2/golden_source.bin` SHA-256 `a2e62f89abc8ae6aa763574fbf4db2b38cf7eb3f5b4fc0b68cbf339a12f9bd90`; `apple2/main.bin`의 디스크 로드 구간과 33,024바이트 모두 일치
- 재구성 디스크 이미지 SHA-256 `22b3b578e254c781fd456fbbf7c22124e970997f328cd83b89ca29a1219c871e`
- 실행기: [Bobbin](https://github.com/benj-edwards/bobbin-ai), commit `b5ca8d3a957132640c94dd00ad6c3d058a49125a`, Apple II+ (`--machine plus`), simple 인터페이스
- 실행기의 해당 commit에는 `src/Makefile.am`의 `bobbin_SOURCES`에서 `control_socket.c`가 누락돼 있어, **임시 빌드 디렉터리에서만** 이를 추가해 빌드했다. 리포의 소스나 바이너리는 수정하지 않았다.

디스크 이미지는 어셈블러 없이 저장된 바이너리에서 만들었다.

```sh
python3 -c 'import build, pathlib; build.DSKFILE=pathlib.Path("/tmp/lode_runner_reference.do"); build.build_disk()'
```

실행기 명령:

```sh
./bobbin --simple --machine plus --disk /tmp/lode_runner_reference.do \
  --breakpoint 60E4 --max-runtime 300
```

`$60E4`는 `MOVE_PLAYER` 호출 직전의 게임 루프 시작점이다. 디버거에서 `save-ram /tmp/name.ram`으로 메모리를 저장하면 실행이 계속되므로, 다음 저장을 하기 전에 다시 브레이크포인트에 멈췄는지 확인한다. JSON은 다음처럼 만든다.

```sh
python3 tools/extract_runtime_snapshot.py /tmp/name.ram \
  fixtures/runtime/name.json --label name --pc 60E4
```

## 캡처 결과

| 파일 | 관찰한 상태 | 캡처 위치 |
| --- | --- | --- |
| `level1_start.json` | 1레벨 시작: 플레이어 `(열 14, 행 14, 오프셋 2/2)`, 금 6개, 경비병 3명, 목숨 5개 | `$60E4` |
| `level1_left_once.json` | 키보드 모드에서 `J` 한 번: 플레이어 열은 14, 가로 오프셋은 `2→1` | `$60E4` |
| `level1_gold_pickup.json` | 이어서 오른쪽 `L` 연속 입력: 금 `6→5`, BCD 점수 `00000000→50020000`(+250), 플레이어 열 17 | `$60E4` |
| `level1_hole_open.json` | 시작 상태에서 왼쪽 굴착 `U`: 활성 보드 `(13,15)`의 벽돌 `1→0`, 배경 보드는 `1`, 복구 타이머 179 | `$60E4` |
| `level1_fall_into_hole.json` | 구덩이 생성 후 `J` 연속 입력: 플레이어 `(13,15)`, 세로 오프셋 0, 생존 | `$656F`, 플레이어 행 변경 직후 |
| `level1_death.json` | 같은 구덩이 경로에서 `ALIVE`가 `1→0`; 플레이어 `(13,15)`, 복구 타이머 1 | `$6E02`, 사망 판정 직후 |

`level1_left_once`, `level1_hole_open`, `level1_fall_into_hole` 시나리오는 디버거에서 `$95` (`INPUT_MODE`)를 `$CB`로 설정해 키보드 모드로 실행했다. 이는 원본의 제어키로도 선택할 수 있는 모드다. 이 조작을 별도로 기록하는 이유는 기본 시작 스냅샷의 입력 모드가 `$CA`(조이스틱)이기 때문이다. 금 수집 시나리오에는 `L`을 20개 큐에 넣고 `$93` (`GOLD_COUNT`)의 변경을 감시했다. 굴착 시나리오에서는 `$09B1` (활성 보드의 행 15, 열 13), 낙하에서는 `$01` (`PLAYER_ROW`), 사망에서는 `$9A` (`ALIVE`)를 감시했다.

마지막 사망 스냅샷은 `ALIVE`가 바뀐 순간의 관찰이다. 정확한 사망 원인과 이후 목숨 차감/재시작까지 이 스냅샷 하나로 단정하지 않는다. 포팅 코드의 사망 처리를 검증할 때는 그 이후의 루프 경계도 별도로 캡처해야 한다.

## 사용 방식

포팅 코드의 레벨 시작과 각 입력 시나리오에서 `GameState`를 같은 형식으로 내보내고, `player`, `guards`, `holes`, `gold_remaining`, `score_bcd_bytes`, `active_board`, `background_board`를 비교한다. `ram_sha256`은 원본 덤프 출처 확인용이며 네이티브 코드의 출력과 비교하지 않는다. `guard_phase`와 경비병의 세부 상태를 비교할 때는 스냅샷마다 입력 횟수와 캡처 위치가 같아야 한다.

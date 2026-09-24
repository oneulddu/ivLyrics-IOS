# 원본 통합: 1.3.18 (빌드 57)

## 범위와 이력

- 포크: `oneulddu/ivLyrics-IOS`, 기준 `05317de` (`main`).
- 원본: `ivLis-Studio/ivLyrics-IOS`, `main`의 `5d86b95`까지 미병합 커밋 24개. 직전 통합 지점은 `a99ba5a`.
- 원본 최신 릴리스는 1.3.17 (빌드 56). 포크 앱 버전은 Debug/Release 모두 1.3.18, 빌드 57이다.
- 작업 브랜치: `feature/sync-upstream-0924`, 시작 SHA `05317de`. 기존 기여 브랜치와 작업 폴더는 변경하지 않는다.
- 일반 merge commit으로 통합하고 GitHub에서도 merge commit을 사용해 원본 ancestry를 보존한다. 원본 릴리스 태그는 포크에 게시하지 않는다.

## 충돌 해소 결정

- 원본의 `lyricsProvider*` 설정은 포크의 표준 공급자(`standardLyricsProvider*`)로 옮긴다. 다중 공급자 모드의 `lyricsProviderOrder`, `lyricsProviderEnabled`, `lyricsMultiProviderTypes`는 기존 의미를 유지한다.
- 곡별 가사 공급자 선택은 `track_lyrics_provider.<곡 키>`에 저장하고 현재 유효한 모드 안에서만 적용한다. 선택이 다중 공급자 모드를 켜거나 권한을 주지 않으며, 원격 차단·Deezer 인증·정책 버전은 기존 평가 경로를 그대로 거친다. 현재 모드에서 쓸 수 없는 선택은 저장만 유지하고 자동 선택으로 동작한다. 정책 재검증은 곡별 snapshot을 기준으로 해 선택이 정책 변경으로 오인되지 않게 한다. 가사 메뉴의 공급자 목록도 현재 모드에서 고를 수 있는 공급자만 보여 준다.
- 원본의 "한 번의 가사 로딩 안에서 싱크 응답 재사용"은 포크의 표준 경로와 다중 공급자 경로 모두에 적용한다. 캐시 삭제 시 진행 중인 로딩을 무효화하고 공급자 캐시도 함께 비운다. 새 로딩마다 기여자 개인정보를 재검증한다.
- 설정은 원본처럼 검색창과 별도 "가사 제공자" 탭을 사용한다. 탭 내용은 포크의 표준/다중 모드 전환, 공급자별 허용 유형과 순서, Deezer 인증, 원격 차단 안내다. 검색은 현재 모드에서 보이는 공급자 카드와 모드·Deezer·법적 안내 카드로 이동한다.
- AI 설정은 원본의 연결 목록과 모델 조회(`AIProviderModels`)를 쓰고 포크의 옛 Paxsenix 모델 조회 상태는 제거한다.
- PiP는 원본의 선택 캐시와 정적 프레임 캐시를 쓰고, 포크의 겹침 행 표시·배경 이미지 캐시·글자/번역 크기·자동 진입과 활성 행 전체 기준 프레임 주기를 유지한다. 정적 프레임에는 제목·아티스트·아트워크·배경만 들어간다.
- 가사 화면은 원본의 표시 인덱스 스냅샷을 쓰되, 활성 표시 항목이 없을 때만 원본 행 기준 위치를 찾는 포크 동작과 누적 보컬 종료 시점 기반 자동 간주 계산을 유지한다. 문화 주석은 포크의 행 렌더 입력 캐시를 거치며 원본의 행별 주석 캐시와 함께 무효화한다.
- 원본의 새 회귀 스크립트 중 포크 구조와 맞지 않는 `test-track-selections.py`, `test-openai-connections.py`, `test-sync-load-reuse.py`, `test-pip-selection-cache.py`는 같은 의도를 포크 계약에 맞춰 검사하도록 고쳤다. 새 검증 기준에서 빠져 있던 포크 전용 번역 키 23개를 22개 언어에 추가했다.

## 릴리스 정책

AltStore 카탈로그는 포크 릴리스 이력만 유지하고 원본의 1.3.12~1.3.17 항목은 가져오지 않는다. 릴리스 워크플로는 태그 대상 worktree 빌드와 실제 앱 버전 검증을 유지하고, 원본이 추가한 회귀 스크립트 6개를 태그 대상 worktree 기준 검사 목록에 더한다. 원본의 수동 실행 전용 `iOS Validation` 워크플로는 그대로 들여온다.

## 검증 결과

- Xcode 26.6, iOS 26.5 시뮬레이터: 앱 XCTest 57개 통과. 곡별 선택과 모드·원격 차단·싱크 로딩 무효화를 다루는 신규 테스트 3개 포함.
- LyricsProviderCore 115개 통과(이번 병합에서 변경 없음). 앱 계약 검사 통과.
- 번역: 22개 로케일, 791개 키 통과.
- `scripts/test-*.py` 12개 전체 통과. 릴리스 메타데이터 테스트 2개 통과.
- Release 정적 분석 통과. 미사용 AppIntents 메타데이터 추출 생략 경고 외 경고 없음.
- 무서명 IPA 아카이브·패키징 통과: 1.3.18/57, 번들 ID, 서명·프로비저닝 프로필 부재, SHA-256 확인.
- 시뮬레이터에서 새 "가사 제공자" 탭에 포크의 조회 모드 전환·우선순위·공급자별 허용 유형이 표시되고, 가사 탭에는 공급자 설정이 중복되지 않음을 확인했다. 실제 Spotify 계정 연결, 실기기 PiP, 외부 공급자 네트워크 동작은 검증 범위 밖이다.
- Astra 계획 수립, 백엔드 통합, 독립 코드 리뷰를 거쳤다. 리뷰 지적 세 건은 모두 원본 코드에 동일하게 있는 동작이라 원본과의 일치를 위해 이번 통합에서는 바꾸지 않았다.

## 원본 후속 과제

- 기본 모델이 비어 있고 추가 OpenAI 호환 연결만 설정된 경우, 문화 주석 로딩(`AppViewModel.loadCulturalAnnotationsIfNeeded`)과 AI 연결 테스트(`AppViewModel.testAIConnection`, `AiLyricsRepository.testConnection`)가 기본 모델·첫 키만 확인해 동작하지 않거나 실패로 표시된다. `hasModel`과 연결 fallback을 쓰도록 원본에 제안할 수 있다.
- AI 설정 검색에서 "추가 OpenAI 호환 제공자"나 Pollinations 액세스 토큰 항목을 누르면 현재 선택한 공급자만 펼쳐져 대상 컨트롤로 이동하지 못한다.

## 가져온 커밋

- `e7bb73d` perf(lyrics): reuse prepared ruby and whitespace metadata
- `76e8301` chore: release iOS 1.3.12 build 51
- `ae0f15f` Update AltStore source for v1.3.12
- `874a284` perf(lyrics): reuse sync responses within each iOS lyric load
- `da5d74c` Update AltStore source for v1.3.13
- `715ca4b` docs: describe iOS 1.3.13 request reuse accurately
- `f6a2757` perf(lyrics): reuse iOS lyric selection and release 1.3.14
- `4e3c721` Update AltStore source for v1.3.14
- `987ceb2` perf(lyrics): stop centering lookup at the next timed row
- `aae85d0` perf(lyrics): reuse display indices with timeline snapshots
- `e3ba96f` perf(pip): reuse static lyric frame backgrounds
- `e835753` Update AltStore source for v1.3.15
- `a53d78b` feat: release iOS 1.3.16 with configurable AI connections and complete translations
- `f71c54f` Update AltStore source for v1.3.16
- `f867044` feat: restore iOS lyric regeneration and provider connection tests
- `9773b3e` fix: honor iOS background blur and preserve album cover framing
- `b57a8d0` feat: select iOS lyric providers per track
- `5d0293f` feat: choose and save iOS background videos per track
- `379f92e` feat: align iOS settings navigation and search with desktop
- `4e465ce` fix: route iOS settings search to background and provider controls
- `2cba75c` feat: add native DeepL translation provider on iOS
- `846ecff` fix: align iOS Gemini thinking configuration with Android
- `631a3f5` chore(release): prepare iOS v1.3.17
- `5d86b95` Update AltStore source for v1.3.17

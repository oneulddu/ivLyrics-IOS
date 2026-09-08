# 원본 통합: 1.3.12 (빌드 51)

## 범위와 이력

- 포크: `oneulddu/ivLyrics-IOS`, 기준 `7ccd9fd` (`main`).
- 원본: `ivLis-Studio/ivLyrics-IOS`, `main`의 `a99ba5a50894acabbff83d63efe24a44d3b14029`까지 미병합 커밋 40개.
- 공통 조상: `2373bde`. 원본 최신 릴리스는 1.3.11 (빌드 50).
- 작업 브랜치: `feature/sync-upstream-0909`, 시작 SHA `7ccd9fd`. 기존 기여 브랜치와 작업 폴더는 변경하지 않는다.
- 일반 merge commit으로 통합하고 GitHub에서도 merge commit을 사용한다. squash/rebase나 기존 태그 이동 없이 원본 ancestry를 보존한다.
- Debug/Release 앱 버전은 모두 1.3.12, 빌드 51. 최종 main 병합 커밋에 annotated tag `v1.3.12`를 붙인다. 원본의 릴리스 태그는 포크에 게시하지 않는다.

## 선검토와 충돌 해소 결정

- 원본 설정 화면의 다섯 탭, 그룹과 기본 컨트롤, 화면 설정과 AI 제공자 펼침을 반영한다. 포크의 일반/다중 공급자 선택, 공급자별 허용 유형·순서·Deezer 인증·원격 정책은 유지한다.
- 제목 번역과 가상 노래방 애니메이션의 새 설치 기본값은 원본대로 끈다. 기존에 저장된 선택값은 유지한다.
- 독립된 겹침 가사를 한 보컬의 배경 파트로 합치던 `CrossLineVocalNormalizer`와 호출을 제거한다. TTML의 명시적 lead/background 관계는 보존하고, 화면과 PiP가 동시에 진행 중인 원본 행들을 각각 표시한다.
- 포크의 간주 구조 선계산을 유지하면서 앞선 긴 보컬의 종료 시점을 누적해 짧은 후속 행 때문에 잘못된 간주가 생기지 않게 한다. 원본의 구간 캐시와 모션 준비 캐시를 결합한다.
- PiP의 배경 이미지 캐시, 자동 진입, 글자/번역 크기 및 잘림 방지 레이아웃은 보존한다. 원본의 겹침 행 표시와 지속적인 모션 준비 캐시를 추가하고 모든 활성 행을 고려해 프레임 주기를 선택한다.
- Spotify의 선택적 Web API, 저장 인증 검증·활성 상태 복구는 보존한다. 큐의 사용 가능한 다음 곡 선택과 재시도, HTTP 429 기한 보존, 비어 있는 재생 응답의 backoff를 반영한다.
- 원본의 디스크 정리 동시 접근 보호와 파일 변경 여부 재확인을 반영한다. 다중 공급자 코어, 가사 정책 검사, 캐시 provenance와 기여자 개인정보 재검증은 유지한다.
- 병합 중 중복으로 들어온 인증 함수와 설정 바인딩을 정리한다. 취소된 요청이 표준 가사 캐시를 기록하지 않도록 기존 정책 검증 경로에 취소 검사를 결합한다.

## 릴리스 정책

포크의 태그 대상 worktree 빌드, 실제 앱 버전 검증, 기존 AltStore 카탈로그 이력 및 파일 체크섬 처리를 유지한다. 새 회귀 검사도 태그 대상 worktree에 들어 있는 스크립트를 실행한다. 스크립트 도입 전의 과거 태그는 해당 검사가 없음을 명시하고 기존 검증을 수행한다.

Discord 전송은 원본의 수동 실행 입력 `notify_discord`를 반영하되, 알림 실패가 릴리스를 막지 않는 포크 정책을 유지한다. AI 노트 생성이 불가능하면 기존 정형 릴리스 노트 fallback을 허용한다.

태그 게시 전에 번역, 코어, 앱 계약, 재생·구간 캐시·겹침 회귀 검사, 앱 XCTest, Release 정적 분석/무서명 빌드 및 독립 코드 리뷰를 완료한다. 태그 후에는 릴리스 작업 결과와 IPA·SHA-256·버전 정보, AltStore 최상단 1.3.12/51 및 포크 다운로드 URL, 이전 카탈로그 항목 보존을 확인한다. 실패 시 기존 태그를 이동하지 않고 원인을 확인한 뒤 필요한 경우 같은 태그로 재실행한다.

## 검증 결과

- Xcode 26.6, iOS 26.5 시뮬레이터: 앱 XCTest 51개 통과.
- LyricsProviderCore: 115개 통과. 앱 계약 검사 통과.
- 번역: 22개 로케일, 703개 키 통과.
- 재생·모션: 79개 assertion 통과.
- 타임라인 캐시: 729,562개 assertion 통과. 동일 구간 1,400개 쿼리가 한 번의 계산을 공유.
- 공급자 겹침: 36개 assertion 통과.
- 릴리스 메타데이터: 2개 테스트 통과.
- 격리 시뮬레이터에서 초기 설정, 메인 화면과 새 설정 탭을 열어 레이아웃 및 공급자·허용 가사 유형 컨트롤 보존을 확인했다. 실제 Spotify 계정 연결/기기 PiP 전환은 합성 테스트와 시뮬레이터 검증 범위 밖이다.
- Release 정적 분석 통과. 미사용 AppIntents 메타데이터 추출 생략 경고 외 오류 없음.
- 독립 Astra 코드 리뷰의 P2 두 건을 수정했다. 큐 HTTP 429의 300초 초과 대기 시간을 온전히 보존하고, 겹침 PiP도 번역·발음 전체 이미지를 측정해 각 행 안에 축소한다.
- 신규 회귀 테스트 3개를 포함한 영향 범위 XCTest 23개 재검증 통과. 기존 전체 51개와 합쳐 고유 테스트 54개가 검증됐다.

- 수정 후 Release 정적 분석 및 무서명 IPA 아카이브/패키징 재검증 통과. 앱 버전 1.3.12/51, 번들 ID, 서명·프로비저닝 프로필 부재와 SHA-256 일치를 확인했다.
- 리뷰어가 두 수정 범위를 재확인했고 남은 P1/P2 지적 없음.

## 가져온 커밋

- `60421b4` perf(cache): move disk maintenance off the write path
- `400f681` Merge pull request #6 from oneulddu/contrib/disk-cache-maintenance
- `cae5cf0` fix(release): make IPA layout validation reliable
- `0642b0c` chore(release): prepare 1.3.4
- `d4e221b` Update AltStore source for v1.3.4
- `4e89449` feat(spotify): add queue authorization primitives
- `871245a` feat(spotify): add an opt-in Web API setting
- `3e4290b` feat(spotify): coordinate opt-in Web API access
- `28b13bb` feat(spotify): prefetch the next queued track
- `aeab78f` feat(settings): expose Spotify Web API controls
- `06fd333` fix(spotify): harden Web API recovery and prefetch
- `c558687` Merge remote-tracking branch 'upstream/main' into contrib/spotify-web-api-prefetch
- `349dcbb` fix: harden Spotify queue prefetch
- `446d66a` feat(spotify): add opt-in Web API prefetch (#9)
- `5dadf2c` chore(release): prepare 1.3.5
- `67e57fc` Update AltStore source for v1.3.5
- `3321f0a` feat(lyrics): align iOS karaoke motion with desktop
- `71fd057` chore(release): prepare 1.3.6
- `4e6116f` Update AltStore source for v1.3.6
- `0ff2b3c` Release 1.3.7 with desktop karaoke motion and accurate provider status
- `328fe0f` Update AltStore source for v1.3.7
- `a6a97f4` Default title translation and virtual karaoke off for 1.3.8
- `7541423` Update AltStore source for v1.3.8
- `941db45` Clarify disabled defaults in 1.3.8 catalog notes
- `74242b9` Bound furigana results and release caches under memory pressure
- `915defa` Back off Spotify playback polling after empty or failed responses
- `0600a2d` Share lyric timeline queries until structural boundaries change
- `9d91c54` Retain karaoke preparation across picture-in-picture frames
- `f5b9867` Preserve playback rate limits when older refreshes finish
- `ed7a1b6` chore: release iOS 1.3.9 build 48
- `77e430f` Update AltStore source for v1.3.9
- `49c0f23` Preserve independent overlapping provider lyric lines
- `7d79866` test: validate provider overlap behavior before iOS releases
- `8129972` chore: release iOS 1.3.10 build 49
- `a1c3109` Update AltStore source for v1.3.10
- `30b18cc` docs: clarify iOS 1.3.10 overlap fixes in AltStore notes
- `ebe6197` Redesign settings with compact grouped native controls
- `6454657` chore: release iOS 1.3.11 build 50
- `71fe0c5` Update AltStore source for v1.3.11
- `a99ba5a` docs: describe iOS 1.3.11 settings redesign in AltStore

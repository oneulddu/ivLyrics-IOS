# 가사 공급자 통합 설계 및 구현 계획

> 상태: Core 및 iOS 앱 통합 구현 반영
>
> 대상: ivLyrics iOS 17+, Swift 5
>
> 참조 구현: [`oneulddu/musicxmatch-api`](https://github.com/oneulddu/musicxmatch-api), 커밋 [`87eb9b446c568af206f80ef45ac4f5b1fcb98437`](https://github.com/oneulddu/musicxmatch-api/tree/87eb9b446c568af206f80ef45ac4f5b1fcb98437) (2026-07-11 확인)
>
> 문서 목적: Musixmatch, Deezer, Unison, Bugs, Genie 다섯 공급자를 안전하게 단계 도입하기 위한 구현 청사진과 검토 체크리스트

## 1. 결론과 기본 결정

기존 `LyricsRepository`의 Spotify 메타데이터 조회, ivLyrics `sync-data`/OpenDB, LRCLIB 흐름은 유지한다. 다섯 신규 공급자와 기존 LRCLIB는 공통 `LyricsProvider` 경계 뒤의 어댑터로 다루고, `LyricsProviderOrchestrator`가 조회 순서·동시 실행·취소·오류 격리를 담당한다. `LyricsRepository`는 유효 정책 결정, 허용된 캐시 선조회, 필요한 경우의 메타데이터 및 `sync-data` 단일 조회, 오케스트레이터 호출, 노래방 보강을 조정하는 얇은 계층으로 동작한다.

기본 동작은 다음과 같이 정한다.

1. 기존 설치와 새 설치 모두 기본 모드는 `.legacy`다. 설정값이 없거나 알 수 없거나 손상됐어도 `.legacy`로 정규화한다.
2. `.legacy`는 즉시 반환 가능한 karaoke 캐시가 없을 때 현재의 `Spotify 메타데이터 -> sync-data -> LRCLIB 직접/검색 -> sync-data 적용` 경로를 의미와 순서까지 그대로 보존한다.
3. `.multiProvider`는 내부 빌드, 사용자의 명시적 선택, 또는 서명 검증된 원격 cohort로만 켠다. 전역 원격 중단은 진행 중 작업과 관계없이 유효 모드를 즉시 `.legacy`로 낮춘다.
4. 로컬/캐시된 정책과 denylist를 먼저 평가한 뒤 허용된 캐시를 확인한다. `.legacy`의 fresh karaoke 캐시는 현재처럼 Spotify와 `sync-data` 네트워크 요청 없이 즉시 반환한다.
5. 기본 가사 캐시 또는 cache miss일 때만 Spotify/ISRC를 해석한다. ISRC가 확보되면 `sync-data`를 정확히 한 번 조회하고, 확보되지 않으면 호출하지 않는다. 응답은 선택 전의 완전한 `SyncDataSelectionContext`와 선택 후의 노래방 적용에 함께 사용한다.
6. 실험 모드도 `sync-data.lrclibId`가 있으면 LRCLIB 직접 조회를 가장 먼저 보존한다. 그 뒤 Musixmatch를 우선 시도하고, Deezer·Unison·Bugs·Genie·LRCLIB 검색 어댑터를 제한된 동시성의 fallback으로 명시적으로 포함한다.
7. fallback 결과는 네트워크 도착 순서로 고르지 않는다. 제한 시간 안에 필요한 상위 후보를 모은 뒤 가사 시간 품질, 구성된 공급자 순서, 매칭 점수, 공급자 트랙 ID 순으로 안정 정렬한다.
8. Deezer는 사용자가 직접 인증 정보를 넣고 명시적으로 켠 경우에만 참여한다. 배포본에 Deezer ARL을 포함하지 않는다.
9. 공급자별 기능 플래그와 원격 중단 스위치를 두고, 공급자 한 곳의 장애가 전체 가사 흐름을 막지 않게 한다.
10. 다섯 신규 공급자 모두 비공식·사설·스크래핑 방식의 엔드포인트를 사용하므로 서비스 약관, 가사 권리, App Store 심사는 출시 차단 조건이다.
11. Unison TTML의 양의 길이를 가진 음절 또는 lead/background 보컬 파트가 있으면 공급자 자체의 풍부한 타이밍을 최종 karaoke로 보존하고 `sync-data`로 덮어쓰지 않는다. Unison LRC/plain은 기존 선택 후 적용 규칙을 따른다.

이 문서에서 **확인됨**은 현재 앱 또는 참조 커밋에서 직접 확인한 사실이고, **권고**는 iOS 구현 시 적용할 설계 결정이다. 구체 파일명은 구현 조사 중 프로젝트 구조에 맞게 바꿀 수 있으나 책임 경계와 계약은 유지한다.

## 2. 범위

### 포함

- Musixmatch, Deezer, Unison, Bugs, Genie의 검색·후보 매칭·가사 조회·정규화
- 공급자 공통 요청·후보·결과·오류 형식
- 자동 공급자 선택, 제한 동시성, 상위 순위를 보호하는 안전한 취소, 회로 차단기
- 공급자별 설정, 기능 플래그, 원격 중단 스위치
- 공급자 출처가 포함된 메모리·디스크 캐시
- Deezer ARL 및 세션성 인증 값의 Keychain 저장
- 파서·전송·매칭·오케스트레이션·캐시·Keychain 검증 전략
- 관측 지표, 단계 출시, 롤백 절차

### 제외

- 이 문서 단계에서의 Swift 런타임 구현과 Xcode 프로젝트 수정
- 공급자 웹사이트에서 사용자 인증 정보를 자동 추출하는 기능
- 가사 번역, 발음, 후리가나, 화면 렌더링 방식 변경
- 기존 ivLyrics `sync-data` 형식이나 OpenDB 서버 변경
- Spotify 비공식 `spclient`의 `color-lyrics` 사용
- 서버 프록시 구축 또는 참조 Rust 브릿지의 직접 포함

Spotify Web API는 가사를 제공하지 않는다. `spclient color-lyrics`는 별도의 비공식 공급자 후보일 뿐이며 이번 다섯 공급자 통합 범위에는 넣지 않는다.

## 3. 현재 상태와 근거

### 3.1 앱 구조

**확인됨:** [`ivLyrics-IOS/LyricsRepository.swift`](../ivLyrics-IOS/LyricsRepository.swift)는 하나의 `actor` 안에서 다음 책임을 함께 가진다.

- Spotify Client Credentials 토큰과 Web API 검색/트랙 조회
- ISRC 및 Spotify 트랙 ID 보강
- `https://lyrics.api.ivl.is/lyrics/sync-data`와 OpenDB 조회
- LRCLIB 직접 조회와 검색 fallback
- 후보 점수 계산과 선택
- 메모리 및 디스크 캐시
- `sync-data`를 기본 줄 가사에 적용해 노래방 가사로 보강

현재 fresh karaoke 메모리/디스크 캐시는 Spotify와 `sync-data`보다 먼저 즉시 반환된다. 캐시가 일반 기본 가사이거나 없을 때의 주요 네트워크 순서는 `Spotify Web API search -> sync-data -> LRCLIB source/search`이다. `sync-data`는 후처리 전용이 아니다. `lrclibId` 직접 조회뿐 아니라 `lineCharCounts`, `sourceLineCharCounts`, `sourceLyricsFingerprint`, `preferredLyricsSource`, `shouldNormalizeParentheticalLines`, `hasLrclibSource`가 `decorateCandidateForSyncData`, legacy exact-line-shape 분기, 원본 fingerprint/줄 모양 일치, 소스 자격, 괄호 줄 정규화에 영향을 준다. 선택 뒤에는 같은 응답의 `syncBody`를 호환 가능한 기본 줄 가사에 적용해 `karaoke = true` 결과를 만든다. 따라서 구현은 이를 **선택 전 문맥**과 **선택 후 적용**으로 분리하되, 캐시가 즉시 반환되지 않고 ISRC가 확보된 조회에서 `sync-data` 네트워크 호출은 한 번만 해야 한다.

**확인됨:** [`ivLyrics-IOS/AppViewModel.swift`](../ivLyrics-IOS/AppViewModel.swift)는 `LyricsRepository.loadLyrics(track:settings:onSpotifyMetadataResolved:)`를 호출하고, 로드된 결과를 기본 가사로 보관한 뒤 번역·발음·후리가나 등 후속 보강을 수행한다. 공개 호출 형태를 한 번에 크게 바꾸면 화면 계층까지 영향이 번진다.

**확인됨:** [`ivLyrics-IOS/Models.swift`](../ivLyrics-IOS/Models.swift)의 `LyricsResult`는 `lines`, `providerLabel`, `detail`, `karaoke`, `isrc`, `spotifyTrackId`, `contributors`를 이미 표현한다. 첫 도입에서는 이를 UI 경계 모델로 유지할 수 있다. 다만 내부 공급자 결과에는 공급자 ID, 공급자 트랙 ID, 가사 형식, 매칭 근거, 캐시/오류 진단 같은 더 풍부한 출처 정보가 필요하다.

**확인됨:** [`ivLyrics-IOS/DiskCaches.swift`](../ivLyrics-IOS/DiskCaches.swift)의 기본 가사 디스크 캐시는 호출자가 전달한 문자열 키로 `LyricsResult`를 저장한다. 현재처럼 곡 키만 쓰면 설정이나 공급자 변경 뒤 오래된 결과가 섞이고, 공급자 denylist를 캐시 읽기 시점에 집행할 출처도 부족하다.

**확인됨:** Xcode 프로젝트 설정은 iOS 17.0과 Swift 5.0이며, 현재 프로젝트 파일에서 별도 테스트 대상은 확인되지 않았다. 구현 첫 단계에 테스트 대상을 추가하거나 별도 Swift Package로 순수 로직 테스트를 격리하는 결정을 내려야 한다.

### 3.2 참조 구현 사용 범위

참조 저장소의 확인 기준은 위에 적은 고정 커밋이다. 소스는 MIT 라이선스이므로 코드 아이디어를 이식할 때 저작권 고지와 라이선스 조건을 지켜야 한다. MIT 허가는 공급자 API 사용권이나 가사 콘텐츠의 저장·전송·표시 권리를 보장하지 않는다.

참조 구현은 동작 조사 자료이지 그대로 옮길 명세가 아니다. 특히 단순한 위치별 문자 일치율, 데스크톱 로컬 서버 전제, 파일 기반 비밀 저장, 무제한에 가까운 공급자 병렬 실행은 모바일 앱 요구에 맞게 다시 설계한다.

## 4. 공급자 조사표

| 공급자 | 확인된 검색/조회 | 인증 | 결과 우선순위 | iOS 구현 시 핵심 주의점 |
| --- | --- | --- | --- | --- |
| Musixmatch | `apic.musixmatch.com/ws/1.1`; Spotify ID 직접 조회, matcher/search, `track.subtitle.get`, `track.lyrics.get` | Android 앱 모사, 서명된 `token.get`, 캐시된 사용자 토큰 | LRC 자막 후 일반 가사 | 내장 서명 재료 노출 위험, 토큰 갱신 직렬화, 401성 응답 1회만 재시도 |
| Deezer | `api.deezer.com/search`; `auth.deezer.com/login/arl`; `pipe.deezer.com/api` GraphQL | 사용자가 제공한 ARL로 JWT 교환 | 줄 동기화 → 단어 동기화를 줄 LRC로 축약 → 일반 가사 | ARL은 Keychain 전용, 기본 비활성, 인증 실패와 일반 실패 분리 |
| Unison | `https://unison.boidu.dev/lyrics`; 메타데이터와 길이 조합 조회 | 없음 | TTML → LRC → 일반 가사 | TTML 음절·화자·lead/background 보컬 파트 보존, 풍부한 타이밍에 `sync-data` 덮어쓰기 금지, 응답 크기·형식 엄격 검증 |
| Bugs | `m.bugs.co.kr/api/getSearchList`; `music.bugs.co.kr/player/lyrics/T/{id}` 및 `/N/{id}` | 없음 | 동기화와 일반 가사를 병렬 조회 | 공급자 전용 `초|문장` + 전각 구분자 형식 파싱, HTML/JSON 형식 변경 감지 |
| Genie | `www.genie.co.kr/search/searchMain`; `dn.genie.co.kr/app/purchase/get_msl.asp` | 없음 | 타임스탬프 객체를 LRC와 일반 가사로 변환 | HTML 검색 파서, JSONP 검증, `Referer`, 키를 밀리초로 해석 |

### 4.1 Musixmatch

**확인됨:** 참조 구현은 `app_id=android-player-v1.0`, Android 기기 User-Agent와 기기 정보를 사용하고, `token.get` URL을 날짜가 포함된 HMAC-SHA1 방식으로 서명한다. 이후 요청 URL에도 사용자 토큰을 붙여 서명한다. 서명 비밀은 참조 코드에 내장돼 있다.

**확인됨:** 캐시된 사용자 토큰을 먼저 쓰며, 공급자 응답이 토큰 갱신을 지시하는 401 계열 상태(`hint=renew`)로 해석되면 새 토큰을 받은 뒤 원 요청을 한 번만 재시도한다. 네트워크 오류나 다른 4xx를 토큰 문제로 간주해 무한 갱신하면 안 된다.

**확인됨:** Spotify 트랙 ID가 있으면 `track_spotify_id`를 이용한 직접 조회를 지원한다. 직접 조회가 없거나 부적절하면 원 제목/아티스트 및 변형값으로 matcher/search 후보를 얻는다. 선택된 트랙에 `track.subtitle.get`의 LRC를 먼저 요청하고, 동기화 가사가 없으면 `track.lyrics.get` 일반 가사를 요청한다.

**권고:** 사용자 토큰은 계정 비밀과 동일한 등급까지는 아니더라도 민감 세션 값으로 취급해 Keychain에 저장한다. 토큰 요청과 갱신은 공급자 actor 안에서 단일 비행(single-flight)으로 합치고, URL·헤더·응답 본문 전체를 기록하지 않는다. 앱 바이너리에 들어가는 서명 재료와 Android 모사 방식은 역공학 가능하며 언제든 차단될 수 있으므로 법무/배포 검토 및 원격 중단 스위치 없이는 출시하지 않는다.

### 4.2 Deezer

**확인됨:** 검색은 공개 검색 API에 제목·아티스트 질의를 보내고, 결과에서 트랙 ID·제목·아티스트·길이를 얻는다. 가사에는 인증이 필요하며, 사용자가 제공한 ARL 쿠키를 `auth.deezer.com/login/arl`에 보내 JWT를 받은 뒤 `pipe.deezer.com/api`의 GraphQL 가사 질의를 호출한다. 인증 오류가 나면 JWT를 비우고 한 번 갱신한다.

**확인됨:** 결과는 `synchronizedLines`를 가장 먼저 사용한다. 없으면 `synchronizedWordByWordLines`의 단어를 줄 단위로 합쳐 LRC를 만들고, 둘 다 없으면 일반 `text`를 사용한다.

**권고:** ARL은 `UserDefaults`, 설정 스냅샷, 진단 로그, 크래시 정보, 분석 이벤트, 백업 가능한 평문 파일에 절대 저장하지 않는다. `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` 등 앱 사용 방식에 맞는 접근 등급을 보안 검토 후 선택하고 Keychain 서비스/계정 키를 버전 관리한다. 설정 모델은 실제 값 대신 `isConfigured`, 마지막 검증 시각, 마스킹된 상태만 노출한다. 사용자가 끄거나 삭제하면 ARL, JWT, 인증 실패 캐시를 함께 제거한다.

**기본값:** Deezer는 비활성이다. 사용자가 ARL을 저장하고 연결 검증에 성공한 뒤 명시적으로 켜야 자동 모드에 들어간다. ARL 획득을 자동화하거나 앱에 기본값으로 싣지 않는다.

### 4.3 Unison

**확인됨:** Unison은 합성 메타데이터 기준으로 제목·아티스트·앨범·길이를 조합해 조회하고, `ttml`, `lrc`, `plain` 형식을 반환한다. TTML 파서는 줄 음절, 화자 표현(`speaker`, `color`, `fallback`), lead/background 역할과 각 보컬 파트의 `text` 및 음절 타이밍을 공통 공급자 모델에 보존한다.

**권고 및 구현 규칙:** 실제 양의 길이를 가진 줄 음절 또는 보컬 파트 음절이 하나 이상인 Unison 결과만 rich timing으로 판정한다. 이 결과는 앱 `LyricsLine`으로 역할·화자·색·fallback·`kind=vocal`·text·음절을 손실 없이 옮기고 `karaoke = true`로 반환한다. 단순 line-synced LRC나 plain 결과, 빈 음절 배열, 0 길이 음절은 rich timing으로 오인하지 않으며 기존 `sync-data` 적용 규칙을 따른다.

### 4.4 Bugs

**확인됨:** 모바일 검색 API에 제목과 아티스트를 합친 질의를 보내며, 결과에는 곡 ID·제목·아티스트·길이가 있다. 선택된 곡의 동기화 `T`와 일반 `N` 가사 엔드포인트는 병렬로 조회한다.

**확인됨:** `T`와 `N` 응답은 JSON의 `lyrics` 문자열 값을 사용한다. `T` 값은 항목 간 전각 `＃`, 항목 안의 `시간(초)|텍스트` 형식이다. 시간은 부동소수점 **초**이므로 `round(seconds * 1000)`으로 밀리초를 만든다. 예를 들어 합성 fixture `7.3|첫 줄＃8.3456|둘째 줄`은 각각 `7300ms`, `8346ms`가 되어야 한다. `N`의 `lyrics` 값은 줄바꿈을 정규화한 일반 가사다. 한 형식이 없더라도 다른 형식이 유효하면 성공으로 취급한다.

**권고:** `T`와 `N`의 내부 병렬성은 공급자 전체 동시성 예산에 포함한다. 잘못된 항목 몇 개는 건너뛸 수 있지만, 전체 항목 대비 유효 줄 비율이 너무 낮거나 시간이 심하게 역행하면 `providerFormat` 오류로 분류해 오염된 가사를 채택하지 않는다.

### 4.5 Genie

**확인됨:** HTML 검색 결과의 행에서 `songid`, 제목, 아티스트, 길이를 파싱한다. 선택된 곡은 `get_msl.asp?path=a&songid=...` JSONP 엔드포인트에서 조회하며 Genie 홈페이지 `Referer`를 보낸다.

**확인됨:** JSONP 안의 JSON 객체 키가 이미 **밀리초** 타임스탬프이고 값이 가사 문장이다. 숫자 키를 정렬해 LRC와 일반 가사를 만든다. 예를 들어 합성 fixture의 `"7300": "첫 줄"`, `"8346": "둘째 줄"`은 각각 `7300ms`, `8346ms`로 유지해야 하며 1000을 다시 곱하면 안 된다.

**권고:** 문자열 위치에 과도하게 의존하는 파서 대신, 검색 행 범위를 제한한 내결함성 파서와 명확한 필수 필드 검증을 둔다. JSONP는 콜백 괄호 범위를 확인한 뒤 내부 JSON 객체만 디코딩하고, 예상하지 않은 중첩·비숫자 키·과대 응답은 거부한다. HTML 구조 변경은 단순 `miss`가 아니라 `providerFormat`으로 관측한다.

## 5. 목표 구조

```text
AppViewModel
    │ 기존 loadLyrics 호출 유지
    ▼
LyricsRepository (얇은 조정 계층)
    ├─ EffectiveProviderPolicy 결정 (로컬/캐시 정책 + denylist)
    ├─ effectiveMode/출처 승인 후 메모리·디스크 캐시 조회
    │  ├─ legacy fresh karaoke → 네트워크 0회, 즉시 반환
    │  ├─ multiProvider matching v2 karaoke → 즉시 반환
    │  └─ base cache 또는 miss → 네트워크 단계 진행
    ├─ Spotify 메타데이터/ISRC 보강
    ├─ ISRC가 있으면 sync-data 한 번 조회
    │  ├─ 완전한 SyncDataSelectionContext 정규화
    │  └─ 원 응답은 post-selection 적용용으로 보관
    ├─ .legacy → 현재 sync-data + LRCLIB 경로
    └─ .multiProvider → LyricsProviderOrchestrator
       ├─ sync-data lrclibId 직접 조회 preflight
       ├─ Musixmatch 우선 단계
       └─ 결정적 fallback 수집/선택
             │
             ▼
    선택된 기본 가사 + 같은 sync-data 응답
             │
             ├─ 호환 시 karaoke 적용
             ├─ base provider + sync-data provenance 보존
             └─ LyricsCacheEnvelope 저장 / LyricsResult 반환
             │
             ▼
LyricsProviderOrchestrator
    ├─ EffectiveProviderPolicy / FeatureFlags
    ├─ LyricsMatcher
    ├─ 동시성 제한 / bounded collection / 안정 정렬
    ├─ 오류 분류 / CircuitBreaker
    └─ 공급자별 구현
       ├─ LrclibProviderAdapter ─ direct/search + sync-data 선택 문맥
       ├─ MusixmatchProvider ─ session/signing/client/parser
       ├─ DeezerProvider ─ Keychain/auth/client/parser
       ├─ UnisonProvider ─ metadata client + TTML/LRC/plain parser
       ├─ BugsProvider ─ client/parser
       └─ GenieProvider ─ client/HTML+JSONP parser
```

핵심 원칙은 신규 공급자 구현이 UI 모델과 `sync-data` 원문을 알지 못하게 하는 것이다. LRCLIB 어댑터만 정규화된 `SyncDataSelectionContext`를 받아 직접 ID와 후보 형태 힌트를 재사용한다. 공급자는 정규화된 기본 가사와 출처를 반환하고, 오케스트레이터는 채택 결과를 고르며, 저장소는 보관한 동일 `sync-data` 응답을 선택 후 적용한다.

## 6. 내부 계약 초안

아래는 책임과 데이터 요구를 고정하기 위한 Swift 모양의 의사 코드다. 실제 접근 제어자와 파일 배치는 구현 단계에서 조정할 수 있다.

```swift
enum LyricsProviderID: String, Codable, Hashable, Sendable {
    case lrclib, musixmatch, deezer, unison, bugs, genie
}

enum LyricsTiming: String, Codable, Hashable, Sendable {
    case plain
    case lineSynced
}

enum LyricsProviderMode: String, Codable, Hashable, Sendable {
    case legacy
    case multiProvider

    static func normalize(_ rawValue: String?) -> Self {
        guard rawValue == Self.multiProvider.rawValue else { return .legacy }
        return .multiProvider
    }
}

enum DirectIdentifierEvidence: String, Codable, Hashable, Sendable {
    case none
    case isrc
    case spotifyTrackID
    case syncDataLrclibID
}

struct MatchEvidence: Codable, Sendable {
    let titleScore: Double
    let artistScore: Double
    let durationScore: Double
    let durationDeltaMs: Int64?
    let versionPenalty: Double
    let directIdentifier: DirectIdentifierEvidence
    let totalScore: Double
    let policyVersion: Int
}

struct SyncDataSelectionContext: Sendable {
    let lrclibID: Int64
    let lineCharCounts: [Int]
    let sourceLineCharCounts: [Int]
    let sourceLyricsFingerprint: String
    let preferredLyricsSource: String
    let shouldNormalizeParentheticalLines: Bool
    let hasLrclibSource: Bool
    let contextVersion: Int
}

struct LyricsProviderRequest: Sendable {
    let trackKey: String
    let title: String
    let artist: String
    let album: String
    let durationMs: Int64?
    let isrc: String?
    let spotifyTrackId: String?
    let locale: String
    // LrclibProviderAdapter만 소비하고 신규 공급자는 무시한다.
    let syncDataSelectionContext: SyncDataSelectionContext?
}

struct LyricsCandidate: Sendable {
    let provider: LyricsProviderID
    let providerTrackID: String
    let title: String
    let artist: String
    let album: String?
    let durationMs: Int64?
    let availableTiming: Set<LyricsTiming>
    let matchEvidence: MatchEvidence
}

struct ProviderLyrics: Sendable {
    let provider: LyricsProviderID
    let providerTrackID: String
    let lines: [LyricsLine]
    let timing: LyricsTiming
    let rawCopyright: String?
    let matchedCandidate: LyricsCandidate
    let fetchedAt: Date
}

struct ProviderLyricLine: Sendable {
    let startMs: Int64
    let endMs: Int64?
    let text: String
    let syllables: [ProviderLyricSyllable]
    let speaker: ProviderSpeakerPresentation?
    let vocalParts: [ProviderVocalPart] // role lead/background, speaker, text, syllables
}

struct LyricsCacheProvenance: Codable, Sendable {
    let effectiveMode: LyricsProviderMode
    let baseProvider: LyricsProviderID
    let providerTrackID: String
    let timing: LyricsTiming
    let normalizedCandidateTitle: String
    let normalizedCandidateArtist: String
    let normalizedCandidateAlbum: String?
    let candidateDurationMs: Int64?
    let matchEvidence: MatchEvidence
    let matchPolicyVersion: Int
    let parserVersion: Int
    let providerPolicyVersion: Int
    let syncDataApplied: Bool
    let fetchedAtMs: Int64
}

struct LyricsCacheEnvelope: Codable, Sendable {
    let schemaVersion: Int
    let cacheKey: String
    let result: LyricsResult
    let provenance: LyricsCacheProvenance
    let savedAtMs: Int64
}

enum LyricsProviderError: Error, Sendable {
    case miss                    // 정상적인 검색 결과 없음/가사 없음
    case authenticationRequired // 설정되지 않음
    case authenticationFailed   // 설정됐지만 거부/만료 갱신 실패
    case rateLimited(retryAfter: Duration?)
    case transient              // timeout, 연결 단절, 일시적 5xx
    case providerFormat         // HTML/JSON/JSONP/가사 형식 변경
    case policyDisabled         // 로컬/원격 기능 플래그로 차단
    case cancelled
}

protocol LyricsProvider: Sendable {
    var id: LyricsProviderID { get }
    func fetch(_ request: LyricsProviderRequest) async throws -> ProviderLyrics
}
```

공급자 내부에서 검색과 가사 조회가 분리돼도 외부 계약은 한 번의 `fetch`로 단순화한다. 테스트와 수동 선택 기능이 필요해지면 내부 `search`/`load` 계약을 별도로 노출하되, 오케스트레이터가 공급자별 절차를 직접 알게 만들지 않는다.

`SyncDataSelectionContext`는 현재 `LyricsRepository.SyncDataResult`의 선택 관련 값을 손실 없이 옮긴다. `lrclibID == 0`은 직접 ID가 없음을 뜻한다. `lineCharCounts`와 `sourceLineCharCounts`는 legacy exact-line-shape 분기와 후보 줄 모양 비교에, `sourceLyricsFingerprint`는 원본 가사 동일성 확인에, `preferredLyricsSource`와 `hasLrclibSource`는 후보 소스 자격 및 선호도에, `shouldNormalizeParentheticalLines`는 `decorateCandidateForSyncData`의 괄호 줄 정규화에 사용한다. 이 필드들을 축약하거나 일반 문자열 하나로 합치면 현재 LRCLIB 선택 의미를 보존할 수 없다.

`ProviderLyrics`는 `LyricsResult`보다 풍부한 내부 모델로 유지하고, 디스크에는 `LyricsResult` 단독이 아니라 `LyricsCacheEnvelope`를 저장한다. envelope의 `cacheKey`는 실제 조회에 쓴 정규 키와 같고, 현재 곡 삭제는 이 키를 구조적으로 파싱해 `normalizedTrackIdentity` 구성 요소가 일치하는 모든 모드/공급자 봉투를 제거한다. `providerLabel`은 provenance에서 파생한다. `sync-data`가 LRCLIB가 아닌 기본 가사에 적용됐을 때 기존의 하드코딩된 `ivLyrics sync-data + LRCLIB`를 쓰지 않고, 예를 들어 `ivLyrics sync-data + Bugs`처럼 실제 `baseProvider`를 보존한 표시를 만든다. 구조화 provenance가 진실의 원천이고 표시 문자열은 그 파생값이다.

## 7. 후보 매칭

### 7.1 입력 정규화

참조 구현에서 유용한 부분은 다음과 같이 유지한다.

- 원 제목·아티스트 외에 괄호 제거, `feat.`/`ft.` 제거, 첫 아티스트, 구두점/연결자 정규화 변형 생성
- 제목 70, 아티스트 30의 기본 가중치
- 정확한 제목, 포함 관계, 아티스트 일치 보너스
- 재생 시간 차이에 따른 보너스와 큰 차이 페널티
- `live`, `remix`, `cover`, `instrumental`, `karaoke`, `tribute`, `acoustic` 등 원본에 없는 버전 표지 페널티
- Spotify ID 직접 일치는 검색 매칭보다 높은 신뢰도로 취급

### 7.2 Swift 매처 권고

참조 코드의 `similarity`는 같은 문자 위치의 일치 비율이어서 접두어 추가, 단어 순서, 유니코드 조합 차이에 취약하다. 그대로 복사하지 않는다.

권고 매처는 다음 순서로 순수 함수화한다.

1. 유니코드 정규화, 대소문자 접기, 폭/공백/구두점 정리
2. 제목의 버전 표지와 아티스트 목록을 구조적으로 분리
3. 정확 일치와 포함 관계 검사
4. 토큰 기반 Jaccard/Dice와 편집 거리 기반 유사도를 조합
5. 제목 70/아티스트 30 점수에 시간·버전 보정 적용
6. `MatchEvidence`에 각 부분 점수와 적용된 보너스/페널티를 보관

초기 임계값은 참조 구현 숫자를 그대로 확정하지 말고 고정 fixture로 보정한다. 보수적 기본 기준은 다음과 같다.

- Spotify ID 직접 일치: 공급자 메타데이터가 요청 곡과 명백히 충돌하지 않으면 채택
- 일반 검색: 제목 유사도가 높고 아티스트가 최소 기준을 넘거나 포함 관계여야 함
- 제목만 검색: 제목 기준을 더 높이고, 가능한 경우 재생 시간의 근접을 필수 보조 신호로 사용
- 재생 시간 차이 20초 이상: 특별한 직접 식별 근거가 없으면 원칙적으로 거부
- 원본 요청에 없는 `live/remix/cover` 등이 후보에만 있으면 강한 페널티 또는 거부
- 애매한 후보는 잘못된 가사를 보여주기보다 `miss`로 처리

임계값은 공급자별로 다르게 숨기지 말고 공통 정책과 명시적 예외로 관리한다. 매칭 fixture에는 한글/라틴/일본어, 여러 아티스트, 리마스터, 라이브, 리믹스, 동명곡, 괄호 부제, 유니코드 조합형을 포함한다.

## 8. 요청 및 선택 흐름

```text
1. 로컬 설정 + 캐시된 서명 검증 원격 정책 + 전역 중단 + denylist 평가
   └─ absent/unknown/corrupt 또는 global disable → effective mode = legacy
2. effectiveMode에 맞는 메모리/디스크 캐시 조회
   ├─ legacy
   │  ├─ allowed fresh karaoke memory hit → 즉시 반환, Spotify/sync-data 0회
   │  ├─ allowed fresh v1 legacy karaoke disk hit → 즉시 반환, 네트워크 0회
   │  └─ allowed fresh v2 legacy karaoke envelope → 즉시 반환, 네트워크 0회
   ├─ multiProvider
   │  ├─ matching v2 + effectiveMode/provenance/key 승인 + fresh karaoke
   │  │  └─ 즉시 반환, 네트워크 0회
   │  └─ v1, legacy v2, denylisted/mismatched v2 → 사용 금지
   └─ allowed base/non-karaoke hit 또는 miss → 다음 단계
3. 곡 메타데이터 확인 및 Spotify ID/ISRC 보강
4. ISRC가 있으면 sync-data를 한 번 조회
   ├─ lrclibID, 두 lineCharCounts, fingerprint, preferred source,
   │  parenthetical normalization, LRCLIB source eligibility 정규화
   └─ 같은 원 응답 → 선택 후 적용을 위해 보관
5. base/non-karaoke cache hit이면 현재처럼 같은 sync-data 응답 재적용
   ├─ 호환 성공 → karaoke로 업그레이드하여 v2 저장/반환
   └─ 호환 실패/응답 없음 → base 유지하여 v2 저장/반환
6. cache miss이고 effective mode가 legacy면 현재 경로를 그대로 실행
   └─ sync-data lrclibId 직접 → LRCLIB 검색/점수 → sync-data 적용
7. cache miss이고 effective mode가 multiProvider면
   a. sync-data lrclibId가 있으면 LRCLIB 직접 조회 preflight
      └─ 유효 결과면 현재 의미를 보존해 선택
   b. Musixmatch 우선 단계
      ├─ 채택 가능한 lineSynced → 선택
      └─ plain 또는 오류 → plain 보류 후 fallback 진행
   c. Deezer/Unison/Bugs/Genie/LRCLIB 검색을 동시성 2의 대기열로 수집
      ├─ 각 완료 결과를 안정 순위 후보로 보관
      └─ 오류는 유형별 상태/회로 차단기에 반영
8. bounded collection 종료 뒤 안정 정렬로 기본 가사 선택
9. 선택된 기본 가사에 보관한 동일 sync-data 응답을 호환성 검사 후 적용
   ├─ Unison rich TTML → 공급자 타이밍을 karaoke로 보존하고 적용 생략
   └─ Unison LRC/plain 및 다른 공급자 → 기존 호환성 적용 규칙 수행
10. base provider + sync-data provenance로 UI label을 파생
11. effectiveMode가 포함된 LyricsCacheEnvelope 저장 후 LyricsResult 반환
```

참조 자동 모드는 Musixmatch 동기화 가사를 먼저 확정하고, 그렇지 않으면 설정된 Deezer와 Bugs·Genie를 함께 기다린 뒤 공급자 순서상 첫 동기화 결과, 없으면 첫 일반 결과를 고른다. iOS 구현은 Unison을 같은 공통 오케스트레이터에 추가하고 그대로 `join all`만 하지 않는다.

**고정 기본 정책:** `.multiProvider`의 일반 공급자 순서는 `[musixmatch, deezer, unison, bugs, genie, lrclib]`이다. Deezer가 구성·활성화되지 않았으면 건너뛴다. `sync-data.lrclibId` 직접 조회는 이 순위보다 앞선 호환성 preflight이며, LRCLIB 검색은 fallback 순위의 마지막에 명시적으로 남는다. 신규 설치의 활성 공급자 기본값은 오직 `[lrclib]`이고, Unison을 포함한 다섯 비공식 공급자는 명시적 opt-in 전까지 비활성이다. 향후 사용자 설정이 순서를 바꿀 수는 있지만, 정규화된 유효 순서가 없으면 반드시 이 기본값으로 돌아간다.

fallback 공급자 작업은 최대 2개까지 동시에 실행한다. bounded collection은 모든 활성 fallback이 완료하거나 전체 제한 시간이 끝날 때 종료한다. 중간에 좋은 동기화 결과가 도착해도 **그보다 높은 공급자 순위의 작업이 실행 중이면 취소하지 않는다**. 높은 순위 작업이 모두 완료·실패·timeout됐고 현재 결과를 이길 수 있는 대기 작업이 없을 때만 낮은 순위 작업을 취소할 수 있다. URLSession 취소가 실제 요청까지 전파되는지 검증한다.

수집 결과는 네트워크 도착 순서와 무관하게 다음 키로 오름차순/내림차순을 명시해 안정 정렬한다.

1. `timing`: `lineSynced`가 `plain`보다 우선
2. `providerOrderIndex`: 구성된 deduplicated 순서의 낮은 인덱스 우선
3. `MatchEvidence.totalScore`: 높은 점수 우선
4. `providerTrackID`: 정규화된 문자열 오름차순

동일 입력과 동일 결과 집합이면 항상 같은 결과가 선택되어야 한다. 전체 예산과 공급자별 timeout 수치는 계측 후 확정하되, 한 공급자의 기존 47초 요청 timeout을 여러 공급자에 중첩 적용하지 않는다.

선택 후 `sync-data` 적용은 `SyncDataApplier`의 줄 수·문자 수·시간 형태 진단이 호환된다고 판정할 때만 수행한다. 비-LRCLIB 기본 가사라도 호환되면 적용할 수 있지만, `lineCharCounts` 불일치나 빈 적용 결과가 나오면 원래 기본 가사를 유지하고 `syncDataApplied = false`로 기록한다. 이 단계는 공급자 선택 점수를 바꾸거나 다른 공급자를 다시 고르는 단계가 아니다.

### 오류와 회로 차단기

- `miss`: 정상 상태다. 짧은 부정 캐시를 둘 수 있으나 회로 실패 수에 넣지 않는다.
- `authenticationRequired`: Deezer 미설정 등이다. 사용자 설정 상태로 표시하고 자동 재시도하지 않는다.
- `authenticationFailed`: 인증 값 검증 전까지 Deezer를 일시 중단한다. 비밀 값은 로그에 넣지 않는다.
- `rateLimited`: `Retry-After`가 있으면 우선하고 지수 backoff와 jitter를 적용한다.
- `transient`: 짧은 backoff 후 제한적으로 재시도한다. 한 사용자 조회 안에서 무분별한 중첩 재시도는 금지한다.
- `providerFormat`: 파서 변경 가능성이 높으므로 공급자 회로를 빠르게 열고 운영 지표로 경보한다.
- `policyDisabled`: 사용자에게 일반 오류로 노출하지 않고 다른 공급자로 진행한다.

회로 차단기는 공급자별 actor 상태로 두고, 연속 실패 횟수·열린 시각·재시도 가능 시각만 메모리에 보관한다. 원격 중단 스위치는 회로 차단기보다 우선한다. 앱 재시작을 넘어 지속할지는 잘못된 장기 차단 위험을 고려해 후속 결정한다.

## 9. 캐시와 출처

현재 곡 키만으로 저장하는 캐시는 공급자 추가 후 충분하지 않다. 네트워크 작업보다 먼저 로컬 설정, 로컬에 캐시돼 서명이 이미 검증된 원격 정책, 전역 중단, 공급자 denylist를 합쳐 `EffectiveProviderPolicy`를 만든다. 정책을 얻기 위해 이 조회 경로에서 새 네트워크 요청을 만들지 않는다. 전역 중단이면 즉시 `.legacy`로 낮추며, denylist에 있는 `baseProvider`의 봉투는 TTL과 무관하게 거부한다. 그 뒤에만 다음 정규 키로 조회한다.

```text
schemaVersion | effectiveMode | normalizedTrackIdentity | providerPolicyVersion |
enabledProviderSetCanonical | preferredProviderOrderCanonical | credentialGeneration
```

`effectiveMode`는 정규화된 `.legacy` 또는 `.multiProvider` 값이다. 따라서 legacy v2와 multiProvider v2는 같은 곡·정책에서도 충돌하지 않는다. 전역 중단으로 mode가 내려가면 오직 새로 계산한 legacy 키와 허용된 legacy 캐시만 읽고, 기존 multiProvider 메모리/디스크 키는 조회하지 않는다.

`enabledProviderSetCanonical`은 공급자 `rawValue`를 중복 제거한 뒤 사전순 정렬해 결합한다. `preferredProviderOrderCanonical`은 입력 배열에서 첫 등장만 남겨 **순서를 보존**하고, 빠진 활성 공급자는 고정 기본 순서대로 뒤에 붙인다. `Set`의 반복 순서나 설정 저장 구현에 따라 키가 달라지면 안 된다.

공급자 원본/중간 캐시가 필요하면 `providerID | providerTrackID | parserVersion`을 별도 키로 쓴다. `credentialGeneration`은 ARL과 별도로 비민감 저장소에 유지하는 단조 증가 정수다. ARL 저장, 교체, 삭제가 성공할 때마다 증가하고 앱 재실행 뒤에도 감소하거나 초기화되지 않는다. 비밀 값 자체나 그 해시를 캐시 키와 로그에 넣지 않는다.

캐시 값은 6절의 Codable `LyricsCacheEnvelope`이며 다음 정보를 실제 필드로 보존한다.

- effective mode, 공급자 ID와 공급자 트랙 ID
- `plain`/`lineSynced`
- 정규화된 후보 제목·아티스트·선택적 앨범·길이, 전체 `MatchEvidence`
- 공급자 조회 시각 `fetchedAtMs`, 봉투 저장 시각 `savedAtMs`, 스키마/매칭/파서/공급자 정책 버전
- 최종 결과에 `sync-data`가 적용됐는지 여부
- 실제 정규 `cacheKey`

공급자 설정을 바꾸거나 원격 중단이 적용됐을 때 정책 승인 전 캐시를 먼저 반환해서는 안 된다. 원격 denylist는 해당 공급자의 기존 캐시를 항상 읽지 못하게 한다. `cacheKey`는 구분자 escaping과 구성 요소 decoder를 함께 제공하며, 현재 곡 삭제는 문자열 부분 일치가 아니라 디코딩된 `normalizedTrackIdentity`를 비교해 모든 effective mode의 봉투를 제거한다. 캐시 지우기 UI의 전체 삭제는 모든 공급자 네임스페이스를 포함한다.

기존 `LyricsResult` 단독 디스크 형식은 v1 legacy 캐시로 정의한다. 보수적 마이그레이션 기본값은 다음과 같다.

- 유효 모드가 `.legacy`이고 LRCLIB가 denylist에 없을 때만 기존 v1을 읽을 수 있다.
- fresh v1의 `karaoke == true` 결과는 현재 동작과 같이 Spotify와 `sync-data` 호출 없이 즉시 반환한다.
- v1 일반 결과는 legacy base cache로 보관하고 Spotify/ISRC 단계로 진행하며, ISRC가 확보되면 한 번의 `sync-data` 조회 뒤 재적용한다.
- `.multiProvider`에서는 provenance를 검증할 수 없으므로 v1을 cache miss로 취급한다.
- v1을 다중 공급자 봉투로 추정 변환하지 않는다. 다음 정상 네트워크 저장 시 v2 봉투로 교체한다.
- 전역/법적 중단으로 LRCLIB 또는 legacy 캐시 사용이 금지되면 v1도 즉시 거부한다.

기존 provenance 없는 메모리 캐시도 같은 legacy-only 규칙을 적용한다. 허용된 fresh karaoke 결과는 즉시 반환하고, 일반 결과는 `sync-data` 재적용 대상으로만 사용한다. v2는 `cacheKey`, `provenance.effectiveMode`, 정책/파서 버전, denylist를 모두 검증한다. legacy v2와 multiProvider v2의 fresh karaoke 결과는 각각 일치하는 유효 모드에서 즉시 반환하고, 일반 결과는 모드에 맞는 base cache로 재적용한다. 이 조건 밖의 캐시는 miss다.

부정 캐시는 `miss`에만 짧게 적용하고 인증·속도 제한·일시 오류·형식 오류는 동일 TTL로 캐시하지 않는다. 공급자별 캐시가 서로 덮어쓰지 않는지 테스트한다.

## 10. 설정과 비밀 저장

설정 스냅샷에는 비밀 값이 아닌 다음 상태만 전달한다.

```swift
struct LyricsProviderSettingsSnapshot: Sendable {
    let mode: LyricsProviderMode
    let enabledProviders: Set<LyricsProviderID>
    let providerOrder: [LyricsProviderID]
    let deezerConfigured: Bool
    let remoteDisabledProviders: Set<LyricsProviderID>
    let globalRemoteDisable: Bool
    let policyVersion: Int
    let credentialGeneration: UInt64
}
```

설정 로더는 저장된 원문을 먼저 문자열로 읽고 `LyricsProviderMode.normalize`를 적용한다. 값 없음, 알 수 없는 값, 디코딩 실패는 모두 `.legacy`다. `.multiProvider` 요청도 내부 빌드, 명시적 사용자 opt-in, 또는 서명 검증된 원격 cohort 중 하나가 아니면 `.legacy`로 낮춘다. `globalRemoteDisable == true`는 다른 모든 로컬·원격 설정보다 우선해 즉시 `.legacy`가 된다.

비밀 접근은 `SensitiveCredentialStore` 프로토콜 뒤에 둔다. 실제 구현은 Security 프레임워크 Keychain을 사용하며 테스트에서는 메모리 저장소로 대체한다. ARL과 JWT, Musixmatch 사용자 토큰의 수명과 삭제 규칙을 분리한다.

- ARL: 사용자가 저장/교체/삭제한다. 장기 비밀이다.
- Deezer JWT: ARL에서 파생된 단기 세션 값이다. 메모리 우선이며 필요 시 Keychain 저장 여부를 별도 검토한다.
- Musixmatch 사용자 토큰: 공급자 actor가 발급·갱신한다. 비밀 로그 금지와 원자적 교체가 필요하다.
- 서명 재료: 앱에 포함할 경우 추출 가능하다는 전제로 위험을 문서화한다. 난독화를 보안 경계로 보지 않는다.

모든 로그는 공급자, 단계, 상태 분류, 소요 시간, 익명화된 곡 키만 담는다. Authorization/Cookie 헤더, 전체 URL, 쿼리 문자열, 요청/응답 본문, ARL, JWT, 사용자 토큰은 기록하지 않는다. 오류 객체가 URL을 포함할 수 있으므로 그대로 문자열화하지 말고 안전한 오류 매퍼를 거친다.

## 11. 제안 파일 지도

실제 그룹/파일명은 구현 때 Xcode 프로젝트 구성과 기존 유틸리티 재사용 가능성을 확인한 뒤 확정한다.

```text
ivLyrics-IOS/
  LyricsRepository.swift                       # 기존 진입점, 점진적으로 얇게 유지
  SyncDataSelectionContext.swift               # 선택 전 힌트 정규화
  LyricsProviders/
    LyricsProvider.swift                       # 공통 프로토콜/ID
    LyricsProviderModels.swift                 # 요청·후보·결과·오류·출처
    LyricsProviderPolicy.swift                 # mode 정규화, 로컬/원격/denylist 평가
    LyricsProviderOrchestrator.swift           # bounded collection, 안정 선택, 취소
    LegacyLyricsFlowAdapter.swift              # 현재 sync-data + LRCLIB 경로 보존
    LrclibProviderAdapter.swift                # direct/search 및 선택 문맥 적용
    LyricsMatcher.swift                        # 순수 정규화/점수/채택 정책
    ProviderCircuitBreaker.swift               # 공급자별 상태
    ProviderLyricsCache.swift                  # 정규 키, envelope, v1 마이그레이션
    ProviderHTTPClient.swift                   # URLSession 전송, timeout, 안전 오류
    Musixmatch/
      MusixmatchProvider.swift
      MusixmatchClient.swift
      MusixmatchSession.swift
      MusixmatchSigning.swift
      MusixmatchModels.swift
    Deezer/
      DeezerProvider.swift
      DeezerClient.swift
      DeezerAuthSession.swift
      DeezerModels.swift
    Unison/
      UnisonProvider.swift
      UnisonClient.swift
      UnisonParser.swift
      UnisonModels.swift
    Bugs/
      BugsProvider.swift
      BugsClient.swift
      BugsParser.swift
      BugsModels.swift
    Genie/
      GenieProvider.swift
      GenieClient.swift
      GenieParser.swift
  Security/
    SensitiveCredentialStore.swift
    KeychainCredentialStore.swift
```

테스트 대상이 추가되면 공급자별 응답 fixture는 코드와 분리해 `Tests/.../Fixtures/{provider}`처럼 둔다. 실제 응답을 넣기 전에 가사 저작권과 비밀/개인정보를 검토하고, 가능하면 최소 합성 fixture를 사용한다.

## 12. 단계별 구현 계획

모든 공급자를 한 커밋에 넣지 않는다. 각 단계는 독립 검토와 롤백이 가능해야 한다.

### 1단계: 기반 형식과 매처

- 공통 ID, 요청, 후보, 결과, 오류, provenance 계약 추가
- 결정적 `LyricsMatcher`와 매칭 fixture 작성
- `LyricsProviderMode` 안전 정규화와 유효 정책/denylist 선평가 구현
- Codable `LyricsCacheEnvelope`, 정규 캐시 키, v1 legacy-only 마이그레이션 구현
- 정책/denylist 선평가 뒤 legacy memory/v1/v2 및 multiProvider v2 캐시를 모드별로 선조회
- fresh karaoke 즉시 반환과 base cache 재적용 경로를 분리
- `sync-data` 단일 조회를 실제 `SyncDataResult` 필드 전체의 선택 문맥과 선택 후 적용으로 분리
- `decorateCandidateForSyncData`, legacy exact-line-shape, fingerprint/줄 모양 일치, 소스 자격, 괄호 줄 정규화 보존
- 현재 경로의 순서와 의미를 보존하는 `LegacyLyricsFlowAdapter` 경계 마련
- LRCLIB 직접/검색을 명시적인 공급자 어댑터로 감싸고 선택 문맥 전달
- 오케스트레이터를 가짜 공급자로 검증
- 테스트 대상 구성 결정

완료 조건: 기존/신규 설치 모두 `.legacy`이고 현재 `loadLyrics` 동작이 변하지 않는다. 허용된 legacy memory/v1/v2 karaoke hit는 Spotify와 `sync-data` 호출 0회로 반환된다. base cache나 miss에서 ISRC가 확보된 경우에만 `sync-data`가 한 번 조회되어 완전한 LRCLIB 선택 문맥과 후적용 양쪽에 재사용된다. legacy v2와 multiProvider v2 키는 충돌하지 않는다.

### 2단계: Bugs와 Genie

- 인증 없는 두 공급자부터 client/parser 구현
- Bugs 동기화/일반 병렬 조회와 `초 * 1000` 반올림 단위가 고정된 전각 구분자 파서
- Genie HTML 검색과 JSONP 가사 파서, 이미 밀리초인 객체 키 단위 고정
- 합성 fixture, URLProtocol 전송 stub, 형식 변경 오류 검증
- 내부 개발 플래그로만 공급자별 단독 모드 제공

완료 조건: 실제 네트워크 없이 모든 파서와 상태 매핑이 재현 가능하며, 공급자 형식 오류가 LRCLIB 경로를 막지 않는다.

### 3단계: Musixmatch 세션과 서명

- 서명 URL 생성의 고정 벡터 테스트
- 사용자 토큰 Keychain 저장, 단일 비행 발급/갱신
- Spotify ID 직접 조회, matcher/search fallback
- LRC 우선·일반 가사 fallback
- 토큰 갱신 지시 때 정확히 1회 재시도
- 속도 제한 및 원격 중단 스위치 연결

완료 조건: 토큰·서명 값이 로그와 테스트 산출물에 남지 않고, 동시 요청이 중복 토큰 발급을 만들지 않는다.

### 4단계: Deezer와 Keychain

- ARL 저장/교체/삭제 및 상태 전용 설정 모델
- JWT 교환과 인증 오류 1회 갱신
- 검색 및 GraphQL 가사 파싱
- 줄 동기화, 단어 동기화 축약, 일반 가사 순서 검증
- Keychain 접근 실패, 기기 잠금/복원 조건, 로그 삭제 검증

완료 조건: ARL 없이 Deezer는 네트워크 요청을 하지 않고, ARL 삭제 즉시 파생 세션과 캐시 세대가 무효화된다.

### 5단계: 오케스트레이터와 설정 결합

- Unison client와 TTML/LRC/plain 파서, 음절·화자·lead/background 보컬 파트 공통 모델 구현
- `sync-data.lrclibId` 직접 preflight, Musixmatch 우선, Deezer/Unison/Bugs/Genie/LRCLIB 검색 fallback 결합
- 동시성 2, bounded collection, 상위 공급자 보호 취소, 완전한 안정 정렬 구현
- 공급자별 회로 차단기와 오류 관측
- 보관한 동일 `sync-data` 응답의 호환성 검사와 선택 후 적용 연결
- Unison rich TTML은 앱 `LyricsLine`에 무손실 매핑하고 karaoke로 보존하며 `sync-data` 적용을 생략
- 하드코딩된 `ivLyrics sync-data + LRCLIB`를 제거하고 실제 base provider + sync-data 출처로 `LyricsResult` 표시 파생
- 현재 곡/전체 캐시 삭제 범위 확장
- 설정 UI 및 접근성/현지화 반영

완료 조건: 각 공급자를 개별 중단해도 나머지와 기존 LRCLIB 흐름이 정상 작동하고, 결과 도착 순서가 바뀌어도 선택이 동일하다. `sync-data` 적용 결과는 LRCLIB가 아닌 기본 공급자도 정확히 표시한다.

### 6단계: 통제된 출시

- 개발/내부 빌드에서 공급자별 단독 관측
- 명시적 opt-in 또는 서명된 cohort에서만 `.multiProvider` 활성화
- Bugs·Genie부터 소수 사용자 활성화
- Musixmatch는 법무·보안 검토 후 별도 활성화
- Deezer는 사용자 선택형 실험으로만 활성화
- 성공률·오매칭·지연·오류율 기준을 통과할 때 점진 확대

완료 조건: 원격으로 공급자 하나 또는 전체 다중 공급자 모드를 끌 수 있고, 전역 중단 시 캐시 읽기 전에 `.legacy`로 즉시 복귀한다.

## 13. 검증 계획

### 13.1 단위 및 fixture 테스트

- Musixmatch: 서명 고정 벡터, 토큰 응답, 갱신 지시, LRC/일반 fallback, 잘린 JSON
- Deezer: 인증 응답, GraphQL 오류, 줄 동기화, 단어 동기화 축약, 일반 가사, 빈 가사
- Unison: 메타데이터 fallback, TTML 음절·화자·lead/background 보컬 파트, LRC offset/중복 시각, plain, 누락 namespace, 과대·손상 응답, 취소. 실제 가사 대신 짧은 합성 문자열만 사용
- Bugs: 검색 JSON, `T`/`N` JSON의 `lyrics` 값, 한쪽만 존재, 전각 구분자, 잘못된 시간, CRLF. `7.3 -> 7300ms`, `8.3456 -> 8346ms` 고정 벡터로 초 단위 곱셈/반올림 검증
- Genie: 검색 HTML 변형, HTML entity, 아이콘/중첩 태그, 유효/무효 JSONP, 비숫자 키, 시간 정렬. 객체 키 `7300`, `8346`이 같은 밀리초로 유지되고 다시 1000배 되지 않는 고정 벡터 검증
- 공통 LRC: 0, 분 경계, 밀리초 반올림, 중복/역행 시간, 빈 줄, 끝 시간 추론

fixture는 응답 전체 덤프보다 파서 계약을 입증하는 최소 데이터로 만든다. 실제 토큰·쿠키·사용자 식별값·불필요한 실제 가사 전문을 포함하지 않는다.

### 13.2 전송 테스트

커스텀 `URLProtocol`로 다음을 검증한다.

- HTTP 메서드, host/path, 필수 헤더와 안전한 쿼리 구성
- 401/403/404/429/5xx 및 `Retry-After` 매핑
- timeout, 연결 중단, 취소 전파
- 최대 응답 크기와 잘못된 MIME/문자 인코딩
- 재시도 횟수와 backoff가 상한을 지키는지
- 오류 설명과 로그에 URL 쿼리/인증 헤더가 없는지

### 13.3 매칭 테스트

- 정확한 곡, 동명곡, 여러 아티스트, 제목 부제, feat., 리마스터
- live/remix/cover/instrumental/karaoke 오매칭 방지
- 한글·일본어·라틴 문자 및 유니코드 정규화
- 길이 없음/근접/큰 차이
- 공급자마다 후보 순서가 달라도 같은 최종 선택
- 낮은 신뢰도 후보를 `miss`로 거부

### 13.4 오케스트레이터 테스트

- `sync-data.lrclibId`가 실험 모드에서도 검색 공급자보다 먼저 직접 조회됨
- Musixmatch 동기화 성공 시 fallback을 시작하지 않음
- Musixmatch 일반 결과를 보류하고 fallback 동기화 결과를 선택
- LRCLIB 검색이 Deezer/Unison/Bugs/Genie와 함께 명시적 fallback으로 참여
- 낮은 순위 동기화 결과가 먼저 도착해도 실행 중인 높은 순위 공급자를 취소하지 않음
- 높은 순위 공급자가 완료·실패·timeout되어 현재 후보를 이길 수 없을 때만 남은 낮은 순위 작업 취소
- 같은 결과 집합의 도착 순서를 전 순열 또는 대표 permutation으로 바꿔도 `timing -> provider order -> match score -> providerTrackID` 선택이 동일
- 동기화 결과가 없을 때 결정적으로 일반 결과 선택
- Deezer 미설정 시 요청하지 않음
- 동시성 상한 2 준수
- 공급자 하나의 timeout/형식 오류/속도 제한이 전체 실패로 번지지 않음
- 회로 열린 공급자를 건너뛰고 half-open 탐색을 제한
- 호출 task 취소가 모든 자식 요청에 전파
- ISRC가 확보된 비즉시 캐시 경로에서 `sync-data`가 한 번만 조회되고 정규화 선택 문맥과 선택 후 적용에 같은 응답이 재사용됨
- `lrclibID: Int64`, `lineCharCounts`, `sourceLineCharCounts`, `sourceLyricsFingerprint`, `preferredLyricsSource`, `shouldNormalizeParentheticalLines`, `hasLrclibSource`가 손실 없이 LRCLIB 어댑터에 전달됨
- 선택 문맥이 `decorateCandidateForSyncData`, legacy exact-line-shape 분기, fingerprint/줄 모양 일치, 소스 자격, 괄호 줄 정규화 결과를 현재 구현과 같게 만듦
- Bugs 기본 가사에 `sync-data`를 적용하면 `baseProvider == .bugs`, `syncDataApplied == true`가 보존되고 UI label에 LRCLIB가 잘못 표시되지 않음
- Unison rich TTML의 줄 음절과 lead/background 파트 역할·화자·색·fallback·kind/text·음절 시각이 앱 모델에 보존되고 `karaoke == true`이며 `syncDataApplied == false`임
- Unison LRC/plain은 rich timing으로 오인되지 않고 기존 `sync-data` 적용 규칙을 따름
- legacy 모드에서 기존 LRCLIB 직접/검색 및 `sync-data` 결과가 회귀하지 않음

### 13.5 캐시와 Keychain 테스트

- 같은 곡의 서로 다른 공급자·설정 결과 격리
- 유효 로컬/원격 정책과 denylist가 캐시 조회보다 먼저 평가됨
- denylisted base provider의 유효 TTL 봉투도 읽기 거부
- 허용된 fresh legacy karaoke 메모리 hit가 Spotify 0회, `sync-data` 0회로 즉시 반환됨
- 허용된 fresh v1 legacy karaoke 디스크 hit가 Spotify 0회, `sync-data` 0회로 즉시 반환됨
- 허용된 fresh v2 legacy karaoke envelope가 Spotify 0회, `sync-data` 0회로 즉시 반환됨
- legacy base/non-karaoke memory·v1·v2 hit는 Spotify/ISRC 단계로 진행하고, ISRC가 확보되면 정확히 한 번의 `sync-data` 조회 후 재적용됨
- matching multiProvider v2 fresh karaoke envelope는 즉시 반환되고, multiProvider base envelope는 ISRC가 확보되면 한 번의 `sync-data` 조회 후 재적용됨
- multiProvider에서 v1 및 legacy v2를 거부하고, legacy에서 multiProvider v2를 거부함
- 정책/파서 버전 변경 시 이전 캐시 무효화
- 같은 곡의 legacy v2와 multiProvider v2 정규 키가 다르고 서로 충돌하지 않음
- 전역 중단 뒤 multiProvider 키를 읽지 않고 downgraded legacy 키만 조회함
- 동일한 공급자 `Set`을 서로 다른 삽입/반복 순서로 만들었을 때 정규 캐시 키가 동일
- 순서 배열의 중복은 첫 등장만 남고 나머지 상대 순서는 보존됨
- v1 `LyricsResult` 캐시는 legacy에서만 읽고 multiProvider에서는 miss로 처리
- `LyricsCacheEnvelope` Codable 왕복 뒤 `cacheKey`, effective mode, 정규화 후보 메타데이터, `MatchEvidence`, `fetchedAtMs`, `savedAtMs`, sync-data 적용 상태가 보존됨
- 현재 곡 삭제가 `cacheKey`의 디코딩된 곡 identity로 legacy/multiProvider 봉투를 모두 제거하고 다른 곡은 보존함
- 부정 캐시와 일시 오류의 TTL 차이
- 현재 곡/전체 삭제가 모든 관련 네임스페이스를 제거
- Keychain 저장·교체·삭제·읽기 실패
- ARL 최초 저장·교체·삭제마다 `credentialGeneration`이 단조 증가하고 JWT/인증 실패 상태가 무효화됨
- ARL 교체·삭제 뒤 앱을 재실행해도 `credentialGeneration`이 유지되고 이전 캐시 키로 돌아가지 않음
- 설정 스냅샷과 Codable 데이터에 비밀이 들어가지 않음

### 13.6 모드와 정책 테스트

- 신규 설치의 값 없음이 `.legacy`로 정규화됨
- 기존 설치의 값 없음과 이전 버전 설정이 `.legacy`로 정규화됨
- 알 수 없는 문자열, 손상된 저장값, 디코딩 실패가 `.legacy`로 정규화됨
- `.multiProvider`는 내부 빌드, 명시적 opt-in, 서명 검증된 cohort에서만 유효함
- 서명되지 않았거나 만료된 원격 cohort는 `.legacy`임
- 전역 원격 중단이 로컬 opt-in보다 우선해 즉시 `.legacy`로 낮추고, 다중 공급자 캐시도 읽지 않음
- 전역 중단 뒤 동일 곡의 downgraded legacy cache key만 조회됨
- 조회 도중 전역 원격 중단이 적용되면 다중 공급자 자식 작업을 취소하고 legacy 경로로 다시 진입함

### 13.7 선택적 실서버 연기 테스트

CI의 필수 테스트로 두지 않는다. 개발자가 명시적으로 켠 경우에만 최소 곡 집합으로 실행하고, 비밀은 로컬 Keychain/CI 보안 저장소에서 주입한다. 호출 빈도를 낮추고 결과 본문은 저장하지 않는다. 실서버 실패는 공급자 변경 탐지 자료로 쓰되 일반 PR의 결정적 테스트를 불안정하게 만들지 않는다.

## 14. 인수 기준과 성공 지표

### 기능 인수 기준

- 신규/기존 설치와 비정상 설정값의 기본 모드는 `.legacy`이며 기존 Spotify 메타데이터, LRCLIB, `sync-data`, 캐시 흐름이 회귀하지 않는다. 특히 허용된 fresh legacy karaoke memory/v1/v2 hit는 Spotify와 `sync-data` 네트워크 호출 없이 반환한다.
- 각 공급자가 단독 모드에서 유효한 줄 가사 또는 명확히 분류된 오류를 반환한다.
- Unison rich TTML은 공급자 음절·보컬 타이밍이 앱까지 보존되고 `sync-data`가 이를 덮어쓰지 않는다.
- 실험 자동 모드는 `sync-data.lrclibId` 직접 조회와 LRCLIB fallback을 보존하고, 동기화 가사를 일반 가사보다 우선하며 도착 순서와 무관하게 결정적으로 선택한다.
- Deezer 비활성/미설정 상태에서는 ARL 관련 네트워크 호출이 없다.
- 비밀이나 토큰 포함 URL이 로그·분석·크래시 진단·캐시에 존재하지 않는다.
- 공급자 denylist는 캐시보다 먼저 적용되고, 전역 중단은 즉시 `.legacy`로 낮춘다.
- legacy v2와 multiProvider v2는 mode가 포함된 키와 provenance로 격리되고, 전역 강등 뒤에는 legacy 키만 읽는다.
- `sync-data`가 적용되면 공급자 기본 출처와 ivLyrics 보강 출처를 모두 설명할 수 있다.

### 출시 판단 지표

개인정보를 수집하지 않는 범위에서 공급자별로 집계한다.

- 요청 대비 채택 가능한 결과 비율, 동기화 가사 비율
- p50/p95 최종 응답 시간과 공급자별 소요 시간
- `miss`, 인증, 속도 제한, 일시 오류, 형식 오류 비율
- fallback 및 조기 취소 비율
- 캐시 적중률과 오래된 캐시 거부율
- 수동 재검색/즉시 캐시 삭제/공급자 변경을 오매칭 대리 지표로 활용한 비율
- 크래시, 메모리, 배터리, 네트워크 사용량 변화

초기 목표치는 기존 앱의 실제 기준선을 계측한 뒤 확정한다. 기준선 없이 임의의 성공률 숫자로 출시를 승인하지 않는다. 공급자별 형식 오류 급증, p95 지연 악화, 오매칭 대리 지표 상승은 자동 확대 중단 조건이다.

## 15. 보안·법적·운영 위험과 완화

| 위험 | 영향 | 완화 및 출시 조건 |
| --- | --- | --- |
| 비공식/사설 API 및 스크래핑 | 차단, 계정·법적·심사 위험 | 서비스 약관·App Store·라이선스 검토를 출시 차단 조건으로 지정; 공급자별 원격 중단 |
| 가사 콘텐츠 권리 불명확 | 저장·표시·배포 권리 문제 | 원문 소유권을 주장하지 않음; 필요한 고지/출처/삭제 정책 검토; 캐시 기간 최소화 |
| 앱 내 Musixmatch 서명 재료 | 추출·남용·차단 | 비밀로 간주하지 않는 위협 모델, 요청 제한, 원격 중단; 서버 중계가 필요한지 별도 결정 |
| Deezer ARL 유출 | 계정 세션 침해 | Keychain, 기본 비활성, 로그/백업/분석 제외, 삭제 즉시 파생 상태 제거 |
| HTML/JSONP 형식 변경 | 잘못된 가사 또는 전체 실패 | fixture, 엄격한 필수 필드 검증, `providerFormat` 구분, 회로 차단 |
| Unison JSON/TTML 형식·namespace 변경 | 음절·화자·보컬 파트 손실 또는 잘못된 karaoke | 최소 합성 fixture, 누락 namespace 보완, 크기/줄/음절 상한, rich timing 계약 테스트, `providerFormat` 회로 차단 |
| 과도한 병렬·재시도 | 배터리·데이터·속도 제한 악화 | 동시성 2, 전체 시간 예산, 취소, 공급자별 backoff, 중첩 재시도 금지 |
| 잘못된 후보 선택 | 사용자 신뢰 하락 | 보수적 임계값, 버전 페널티, 길이 검증, 결정적 fixture, 애매하면 miss |
| 공급자별 결과 캐시 혼합 | 설정 변경 후 잘못된 결과 | 공급자/정책/인증 세대 포함 키, 스키마 버전, 격리 테스트 |
| ATS/도메인 누락 | 실제 기기 통신 실패 또는 과도한 예외 | HTTPS 도메인 목록 검토; 임의 로드 허용 금지; 필요한 예외는 최소 범위로 보안 검토 |

ATS 및 개인정보 명세 검토 대상 도메인은 최소 다음과 같다.

- `apic.musixmatch.com`
- `api.deezer.com`
- `auth.deezer.com`
- `pipe.deezer.com`
- `unison.boidu.dev`
- `m.bugs.co.kr`
- `music.bugs.co.kr`
- `www.genie.co.kr`
- `dn.genie.co.kr`

모두 현재 HTTPS지만 인증서, 리디렉션, App Transport Security 동작은 실제 기기에서 확인한다. 공급자 응답의 임의 리디렉션을 따라 다른 host로 인증 헤더나 쿠키를 전달하지 않는다.

## 16. 롤백

롤백 단위는 공급자별, 다중 공급자 전체, 캐시 스키마별로 나눈다.

1. 원격 중단 스위치로 문제 공급자를 즉시 자동 모드에서 제외하고 캐시 읽기 전 denylist를 적용한다.
2. 전역 중단 또는 오케스트레이터 공통 문제면 유효 모드를 즉시 `.legacy`로 낮춰 현재 sync-data+LRCLIB 경로를 사용한다.
3. 법적·보안 사유면 해당 공급자의 기존 cache envelope도 읽지 않도록 denylist하고 민감 세션을 삭제한다. provenance가 없는 v1은 LRCLIB/legacy 금지 시 함께 거부한다.
4. 파서 문제면 공급자 캐시 스키마/파서 버전을 올려 오염 가능 캐시를 무효화한다.
5. 앱 업데이트 롤백이 필요해도 새 설정/캐시를 이전 버전이 안전하게 무시하도록 추가 필드는 선택적이고 버전이 있는 형식으로 저장한다.

롤백 훈련은 출시 전에 실제 네트워크를 끄고도 검증한다. “플래그가 존재함”이 아니라 플래그 변경 후 신규 호출 중단, 진행 중 작업 취소, 캐시 정책 적용, 기존 흐름 복귀까지 확인해야 한다.

## 17. 구현 전 열린 결정

다음 항목은 코드 작성 전에 담당자와 검토자가 명시적으로 닫아야 한다.

- [ ] 다섯 비공식 공급자를 앱에 직접 포함해도 되는지 법무·서비스 약관·App Store 검토 완료
- [ ] MIT 고지 위치와 참조 코드 이식 범위 확정
- [ ] 앱 직접 호출과 통제 가능한 서버 중계 중 최종 배포 구조 확정
- [ ] 테스트 대상을 Xcode 프로젝트에 추가할지, 순수 로직을 Swift Package로 분리할지 결정
- [ ] 고정 기본 순서 위에 사용자별 공급자 순서 편집을 첫 출시부터 제공할지 후속 기능으로 둘지 결정
- [ ] 원격 중단 설정의 신뢰 가능한 배포 경로와 서명/캐시 정책 확정
- [ ] 공급자별/전체 timeout 및 회로 차단 임계값을 기준선 계측 후 확정
- [ ] 캐시된 가사의 보존 기간과 법적 중단 시 삭제 정책 확정
- [ ] Deezer JWT를 메모리에만 둘지 Keychain에도 저장할지 위협 모델에 따라 결정
- [ ] Keychain 접근성 등급과 앱 재설치/기기 이전/백업 동작 확정
- [ ] 사용자에게 표시할 공급자 출처·저작권·인증 실패 안내 문구와 현지화 확정
- [ ] 수집 가능한 운영 지표와 개인정보 처리 고지 범위 확정

## 18. 리뷰 체크리스트

### 설계

- [ ] 신규 공급자 구현이 `LyricsResult`, 화면, `sync-data` 원문에 직접 의존하지 않고 LRCLIB 어댑터만 정규화 선택 문맥을 받는다.
- [ ] 기존/신규 설치가 `.legacy`로 시작하고 현재 경로가 그대로 작동한다.
- [ ] multiProvider에도 LRCLIB 직접 preflight와 검색 fallback이 명시돼 있다.
- [ ] 유효 기본 순서가 `[musixmatch, deezer, unison, bugs, genie, lrclib]`이고 기본 활성 공급자는 LRCLIB뿐이다.
- [ ] 동기화/일반 가사와 `karaoke` 보강을 구분한다.
- [ ] Unison rich TTML의 음절·화자·lead/background 보컬 파트가 앱 모델에 보존되고 `sync-data`가 덮어쓰지 않는다.
- [ ] 매칭 정책이 순수 함수이며 점수 근거를 테스트할 수 있다.
- [ ] 네트워크 동시성·bounded collection·상위 순위 보호 취소·전체 시간 예산이 구조적으로 제한된다.
- [ ] `sync-data` 한 응답이 선택 전 LRCLIB 문맥과 선택 후 적용에 재사용된다.
- [ ] 선택 문맥이 `SyncDataResult`의 두 줄 모양 배열, fingerprint, 선호/자격, 괄호 정규화 값을 손실 없이 보존한다.

### 보안

- [ ] ARL과 세션 토큰은 Keychain 또는 메모리에만 존재한다.
- [ ] 로그, 오류, 캐시 키, 분석 이벤트에 비밀과 전체 인증 URL이 없다.
- [ ] 인증 값 삭제가 파생 토큰과 관련 상태까지 제거한다.
- [ ] host별 헤더/쿠키 전송 범위와 리디렉션 정책이 테스트된다.

### 품질

- [ ] 공급자마다 최소 합성 fixture와 URLProtocol 테스트가 있다.
- [ ] 형식 변경이 `miss`로 숨지 않고 `providerFormat`으로 관측된다.
- [ ] 공급자별 캐시와 부정 캐시가 격리된다.
- [ ] 유효 정책과 denylist가 cache envelope 읽기보다 먼저 적용된다.
- [ ] legacy memory/v1/v2 karaoke hit의 Spotify·sync-data 0회 반환과 base cache 재적용이 검증된다.
- [ ] cache envelope의 mode, 후보 메타데이터, MatchEvidence, 시각, cacheKey 필드가 Codable 왕복과 현재 곡 삭제를 지원한다.
- [ ] legacy v2와 multiProvider v2가 mode 포함 키로 격리되고 전역 강등 후 legacy 키만 읽는다.
- [ ] fallback 도착 순서 permutation, 안전 취소, 회로 차단, 기존 경로 복귀가 자동 테스트된다.
- [ ] Bugs의 초→밀리초 반올림과 Genie의 기존 밀리초 유지가 고정 fixture로 잠긴다.
- [ ] Unison TTML rich timing과 LRC/plain 비-rich 판정이 합성 fixture 및 앱 계약 테스트로 잠긴다.
- [ ] 비-LRCLIB 기본 가사에 sync-data 적용 후 base provider와 표시 출처가 보존된다.
- [ ] 실서버 연기 테스트는 명시적 선택이며 CI 필수 경로를 불안정하게 하지 않는다.

### 출시

- [ ] 법적·약관·App Store 검토가 승인됐다.
- [ ] 공급자별 원격 중단과 전역 `.legacy` 강등이 캐시를 포함해 실제로 검증됐다.
- [ ] 기준선 대비 성공률·지연·오매칭·자원 사용량이 허용 범위다.
- [ ] Deezer는 비활성 기본값이며 배포본에 사용자 인증 값이 없다.

## 19. 참고 링크

- [참조 저장소 고정 커밋](https://github.com/oneulddu/musicxmatch-api/tree/87eb9b446c568af206f80ef45ac4f5b1fcb98437)
- [참조 저장소 Musixmatch 구현](https://github.com/oneulddu/musicxmatch-api/blob/87eb9b446c568af206f80ef45ac4f5b1fcb98437/src/musixmatch.rs)
- [참조 저장소 Deezer 구현](https://github.com/oneulddu/musicxmatch-api/blob/87eb9b446c568af206f80ef45ac4f5b1fcb98437/src/deezer.rs)
- [참조 저장소 Bugs 구현](https://github.com/oneulddu/musicxmatch-api/blob/87eb9b446c568af206f80ef45ac4f5b1fcb98437/src/bugs.rs)
- [참조 저장소 Genie 구현](https://github.com/oneulddu/musicxmatch-api/blob/87eb9b446c568af206f80ef45ac4f5b1fcb98437/src/genie.rs)
- [참조 저장소 매칭 구현](https://github.com/oneulddu/musicxmatch-api/blob/87eb9b446c568af206f80ef45ac4f5b1fcb98437/src/matching.rs)
- [참조 저장소 MIT 라이선스](https://github.com/oneulddu/musicxmatch-api/blob/87eb9b446c568af206f80ef45ac4f5b1fcb98437/LICENSE)

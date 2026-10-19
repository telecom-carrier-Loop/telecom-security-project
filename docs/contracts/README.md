# 공통 계약 인덱스

기준 정본: [통합 개발 확정 기준 v1.0](integration-baseline-v1.0.md).

| 문서 | 책임 | 내용 |
|---|---|---|
| [runtime](runtime.md) | 인프라 담당+A | 빌드·실행·배포 경계 |
| [environment-variables](environment-variables.md) | 인프라 담당+전체 | 변수 이름·환경별 주소·Secret |
| [versions](versions.md) | 인프라 담당, 관제 D | 최초 검증한 패치·이미지 digest 잠금 |
| [api-common](api-common.md) | A | 응답·오류·시간·금액·추적 |
| [auth-api](auth-api.md) | A+C | DB 세션·권한·CSRF·요청 제한 |
| [dashboard-api](dashboard-api.md) | A | 본인 요금제·사용량 |
| [support-api](support-api.md) | A+C | 고객 문의 |
| [membership-api](membership-api.md) | A+인프라 담당+C | 포인트·혜택 |
| [payment-api](payment-api.md) | A+인프라 담당+C | 모의 결제·멱등성 |
| [incident-api](incident-api.md) | A+D | 자동 수신·관리 API·중복 |
| [traffic-flow](traffic-flow.md) | C+인프라 담당+D | 공개·관리·자동화 경로 |
| [k8s-network](k8s-network.md) | 인프라 담당+C | 라벨·CIDR·Service·정책 |
| [event-schema](observability/event-schema.md) | D+전체 | 표준 이벤트·필수 필드·중복 키 |

이 요약과 실행 파일이 다르면 정본을 확인하여 같은 PR에서 함께 수정합니다. 실제 버전·장비·테스트 상태는 검증 전 확정 완료로 기록하지 않습니다.

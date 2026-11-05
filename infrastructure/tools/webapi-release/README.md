# 웹/API 클린 릴리스

정식 절차: [두 노드 웹/API 클린 릴리스](../../../docs/runbooks/webapi-clean-release.md).

- PC1 Windows: `prepare-images.ps1`이 최신 main의 고정 커밋으로 이미지와 검증 도구를 준비하고 양쪽 VM에 전송한다.
- 각 Ubuntu: `release.py import`로 archive·이미지 digest·소스 커밋을 검사한다.
- PC1 Ubuntu: 환경을 보존하려면 `apply-images`, Flask 환경 파일도 반영하려면 `apply`를 사용한다.
- 시작한 릴리스는 `verify`로 확인하며 필요 시 같은 릴리스의 `rollback`을 사용한다.

2026-11-04부터 공개 관리자 UI/API **404를 요구**한다. 공개 ConfigMap과 양쪽 Edge의 실제 차단·내부 API 경계·고객 upstream을 검사하고, 관리 Edge Ready와 API ADMIN 보호도 확인한다. 누락된 차단을 복구하려면 [관리자 차단 절차](../../../docs/runbooks/academy-admin-access.md)를 사용한다. 릴리스 패키지에는 같은 커밋의 `k3s-admin-access.py`가 포함되어야 한다.

DB migration·역할 전환은 자동 실행하지 않는다. 사설 로그인·비허용 PC·VPN 및 NodePort 우회 검사는 별도 현장 검증이다.

2026-11-05 실제 IP 전달용 `telecom-edge-proxytest`가 존재하면 해당 Service·ConfigMap과 두 실행 Pod도 읽기 전용 검사한다. 패키지에는 `loop-client-ip-test.py`가 함께 필요하다. [설정·활성 경로·복구 절차](../../../docs/runbooks/academy-client-ip-preservation.md)를 확인한다. pfSense의 실제 Default Backend와 종단 간 IP 전달은 별도 현장 확인 대상이다.

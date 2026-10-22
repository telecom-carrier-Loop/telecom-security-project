# Kubernetes 템플릿과 현장 적용 상태

2026-10-22에는 PC1·PC2 Ubuntu VM에 k3s를 구성하고 현장 사본에 이미지·DB 설정·ClusterIP·Nginx 연결을 반영해 로그인과 관리자 API를 확인했습니다. 실제 주소·리소스·미검증 항목·내일 pfSense 인계는 [현장 작업 기록](../../docs/operations/2026-10-22-k3s-web-handoff.md)을 확인합니다. DB 전환·복구 영향은 [MySQL 점검](../../docs/runbooks/mysql84-k3s-impact.md)을 함께 확인합니다.

base/는 기존 VLAN 설계 기준의 오프라인 렌더링 가능한 템플릿입니다. 현장 구성과 다르므로 전체를 그대로 적용하지 않습니다. 이미지 태그에 REPLACE_WITH_COMMIT_SHA가 남아 있고 예제 DB·NodePort 주소도 현장 설정으로 바꿔야 합니다.

```powershell
kubectl kustomize infrastructure/kubernetes/base
```

기존 VLAN 설계 기준의 템플릿 적용 전 순서(현재 VLAN 없는 현장과 구분):

1. A 앱 이미지·digest·Health·읽기 전용 파일시스템 호환성 확인.
2. 두 k3s 노드 Ready·VLAN20 NodePort 경로·리소스 확인.
3. 보호된 API Secret과 별도 Migration Secret 준비. 비밀값을 YAML에 기록하지 않음.
4. A Migration 이미지/Job을 릴리스마다 별도 한 번 실행하고 DB·복제 상태 확인.
5. C의 필수 허용/차단 정책과 양 노드의 실제 source/NAT 경로 확인.
6. 앱 배포·각 노드 하나씩 배치·교차 인증·NodePort·Nginx·DB 검증.

NetworkPolicy는 C 소유이므로 이번 인프라 담당 변경에 작성하지 않습니다. 단일 제어부 장애 시험은 공용 PC가 준비된 뒤 전체 팀과 진행합니다.

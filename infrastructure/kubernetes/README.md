# Kubernetes 준비 상태 — 인프라 담당

base/는 오프라인 렌더링 가능한 설계 템플릿입니다. 아직 적용하지 않습니다. 이미지 태그에 REPLACE_WITH_COMMIT_SHA가 남아 있고 실제 앱·Secret·노드가 필요합니다.

```powershell
kubectl kustomize infrastructure/kubernetes/base
```

실제 배포 전 순서:

1. A 앱 이미지·digest·Health·읽기 전용 파일시스템 호환성 확인.
2. 두 k3s 노드 Ready·VLAN20 NodePort 경로·리소스 확인.
3. 보호된 API Secret과 별도 Migration Secret 준비. 비밀값을 YAML에 기록하지 않음.
4. A Migration 이미지/Job을 릴리스마다 별도 한 번 실행하고 DB·복제 상태 확인.
5. C의 필수 허용/차단 정책과 양 노드의 실제 source/NAT 경로 확인.
6. 앱 배포·각 노드 하나씩 배치·교차 인증·NodePort·Nginx·DB 검증.

NetworkPolicy는 C 소유이므로 이번 인프라 담당 변경에 작성하지 않습니다. 단일 제어부 장애 시험은 공용 PC가 준비된 뒤 전체 팀과 진행합니다.

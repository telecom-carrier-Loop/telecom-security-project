# 2026-10-27 웹·DB 복제·백업 복구 및 프론트엔드 재배포

기준: 2026-10-27, Asia/Seoul. 현장 스크린샷과 사용자 보고를 기록했다. 문서 작성 환경에서 현장 서버를 직접 변경하지 않았다. [10월 26일 복구 중 기록](2026-10-26-network-recovery.md)의 후속이다.

## 현재 확인 범위

| 대상 | 근거와 결과 |
|---|---|
| k3s 노드 | PC1 `.7.185`, PC2 `.7.100` 모두 `Ready` 화면 확인 |
| API 장애 원인 | 두 API Pod `0/1`, EndpointSlice 둘 다 `ready: false`; `readiness_db_failed`, readiness 503; 두 Pod에서 `.3.18:3306` TCP 연결 거절 |
| Primary DB | 사용자가 PC1 MySQL이 꺼져 있어 다시 켰다고 보고 |
| k3s HTTPS·DB | `.3.30`을 인증서 검증 대상으로 유지한 `--connect-to` 시험에서 PC1·PC2 NodePort 30443 모두 HTTP 200 / `database: ok` |
| PC2 → pfSense 공개 경로 | 처음에는 Schannel `SEC_E_UNTRUSTED_ROOT`; 프로젝트 CA를 CurrentUser Root에 등록한 후 `https://192.168.3.30/api/health/ready` HTTP 200 / DB ok 확인 |
| 일반 사용자 조회 | 사용자가 `.3.30`에서 고객 상태 조회 가능하다고 보고 |
| 기존 PC3 관리자 경로 | `.7.178:9443` readiness 200, 익명 관리자 API 401; 관리자 로그인 후 운영 대시보드 데이터 표시 확인 |
| MySQL Replica | IO 스레드 No, SQL 스레드 Yes, 오류 2003 / 연결 거절 / 재시도 10회 소진 화면 확인. `START REPLICA IO_THREAD` 후 사용자 복구 완료 보고. 최종 전체 상태 출력은 미첨부 |
| Replica 보호 | server_id 2, read_only 1, super_read_only 1 화면 확인 |
| 백업·감시 | 새 백업 시험 완료 보고와 last-success success 화면 확인. 백업·Discord 감시 작업 모두 Ready, 감시 활성화 및 수동 실행 명령 확인 |
| React 재배포 | 프론트엔드만 변경한다고 확인. 별도 작업 폴더에서 최신 소스로 빌드·두 VM 반입·telecom-web 교체 절차 후 사용자 완료 보고. 최종 이미지 태그·digest·Pod 출력은 미첨부 |

단일 health 요청이나 NodePort 두 주소의 성공이 모든 개별 Pod·모든 업무 기능·고가용성을 검증하지는 않는다. 백업 작업 Ready는 미래 실행 성공을 보장하지 않으며, 오늘 새 백업의 격리 RestoreTest는 아직 확인하지 않았다.

## 네트워크 장애와 DB 장애를 구분한 복구

1. PC1·PC2 VM 네트워크 복구 후 두 노드 Ready를 확인했다. Windows `New-NetRoute` 오류 5는 관리자 권한 부족으로 구분했다.
2. pfSense를 우회한 HTTPS 시험도 502여서 내부 API를 조사했다. edge-health 200은 edge 자체 검사이며 DB 상태 검사가 아니다.
3. API의 liveness 200, readiness 503 및 DB TCP Connection refused를 확인했다. DB 비밀번호 검사 이전의 접속 실패였다.
4. PC1 Docker MySQL 시작 후 두 노드 HTTPS readiness 시험이 200으로 회복됐다. 이미지 재빌드·DB 초기화·복제 초기화는 복구 조치로 사용하지 않았다.
5. PC2의 공개 HTTPS는 CA 미신뢰가 남아 있었다. CA 공개 인증서만 전달하고 원본 파일 해시 비교 후 사용자 신뢰 저장소에 등록하도록 안내했다. 개인키는 배포하지 않았다.
6. Replica는 Primary 중단 중 10회 재시도 후 수신 스레드가 멈춰 있었다. PC1 TCP 3306 연결 확인 후 기존 GTID/TLS 설정을 유지해 `START REPLICA IO_THREAD`로 수신 재개하도록 안내했고 완료 보고를 받았다.
7. 복제 확인 후 백업 시험을 수행하고, 새 성공 기록 이후 Discord 감시를 다시 활성화했다.

기존 IP 미수신과 스위치 재연결의 시간적 연관성은 있으나 스위치 고장·DHCP 근본 원인은 아직 확인하지 않았다. Netplan·Windows 경로의 재부팅 후 유지도 별도 검증 대상이다.

## 백업 결과

- `Loop-MySQL84-PC2-Hourly-Backup`: Ready.
- `Loop-MySQL84-PC2-Backup-Discord-Monitor`: Ready; Enable 및 Start 명령 실행 화면 확인.
- last-success: 시작 `2026-10-27T01:23:00.2081094Z`, 완료 `2026-10-27T01:23:02.0698587Z`.
- 한국 시각으로 약 10:23:00~10:23:02. 백업 폴더명 `20261027-102300-507-7366b6` 확인.
- 정상 시 감시 알림이 없을 수 있다. 오늘 Discord의 실제 복구 메시지 수신 여부는 별도 증거가 없다.
- 복제 재시도 횟수 10은 짧은 장애에도 소진될 수 있다. 재시도 정책 조정·복제 중단 자체 감시는 후속 과제로 남긴다.

## 프론트엔드 재배포와 로컬 변경 보호

현장 PC1 Windows 저장소에 `backend/app.py`, `backend/app/config.py`, `backend/wsgi.py` 수정이 있었고, pull은 config.py·wsgi.py 덮어쓰기 우려로 중단됐다. fetch 결과와 작업 폴더 반영 여부를 구분했다.

- 기존 수정 파일을 삭제하거나 reset하지 않고 `git worktree add --detach <별도 폴더> origin/main`으로 최신 코드를 빌드하도록 안내했다.
- 최신 소스를 PC1 Windows에서 `infrastructure/docker/frontend/Dockerfile`, context `frontend`로 빌드.
- 새 `web-<12자리 커밋>-<시각>` 태그와 revision label 사용. 같은 태그 덮어쓰기를 피했다.
- tar를 PC1·PC2 Ubuntu에 전달하고 각 노드에서 `sudo k3s ctr images import`.
- PC1에서 `telecom-web`의 기존 이미지 기록 후 컨테이너 `web` 이미지만 교체. 기존 ConfigMap·TLS·DB·백엔드 변경 없음.
- 사용자가 재배포 완료 보고. build source 폴더가 다르므로 기존 Windows 작업 폴더의 HEAD와 실제 배포 태그를 혼동하지 않는다.

## 프로젝트의 외부 사용자 정의와 다음 정책

사용자는 **PC1·PC2·PC3를 제외한 같은 학원망 PC를 프로젝트 관점의 외부 사용자**로 정의했다. 이는 공인 인터넷·VLAN·물리 망 분리를 의미하지 않는다.

현재 공개 진입 경로:

```text
학원망 사용자 → 192.168.3.30:443 (PC3 pfSense WAN IP Alias)
             → NAT 192.168.7.185:30443 (PC1 k3s NodePort)
             → telecom-edge → telecom-web / telecom-api
             → PC1 또는 PC2 Pod → PC1 Windows MySQL
```

기존 공개 edge는 `/admin`과 `/api/admin`을 404로 차단하므로 `.3.30` 관리자 화면 실패를 DB 장애로 해석하지 않는다. PC3 전용 `.7.178:9443`은 별도 경로로 정상 조회가 확인됐다.

새 요청은 같은 `.3.30`에서 어느 허용 학원망 PC든 ADMIN 계정으로 관리 기능을 이용하는 것이다. [권한 기반 관리자 접근 전환 절차](../runbooks/academy-admin-access.md)에 사전 검사·제한적 ConfigMap 변경·검증·롤백을 기록했다. **이 정책 변경은 아직 현장에 적용하지 않았다.**

## 남은 작업

- 후속 화면에서 두 API의 실제 DB 계정 `webuser@172.17.0.1`, 두 Pod 1/1 및 rollout 완료를 확인했다. CRUD 전용 계정으로 전환했으며 앱의 쓰기 업무 전체·최신 백업 시험 결과는 별도 확인 대상이다.
- PC1 Windows에도 CA를 등록한 뒤 공개 HTTPS readiness 200 / database ok를 확인했다. 계정 전환 후 Windows의 UNTRUSTED_ROOT 오류는 DB 인증 실패와 구분해 해결했다.
- PC1·PC2 방화벽 보고서에서 Public 이더넷, Public/Private 비활성, Docker TCP Any 허용과 일반 PC의 DB TCP 도달을 확인했다. 이후 수정본으로 PC1 재시도 후 연결·HTTPS 시험 정상 사용자 보고를 받았다. PC2 적용과 전체 관제 회귀는 남아 있으며 [파트별 인계](2026-10-27-db-security-handoff.md)와 [공유 이슈 #40](https://github.com/telecom-carrier-Loop/telecom-security-project/issues/40)에서 추적한다.

- [ ] 공개 주소에서 익명 401 / CUSTOMER 403 / ADMIN 200을 검증한 뒤 관리자 접근 정책 전환 완료 표시.
- [ ] 다른 학원 사용자 PC의 CA 신뢰·로그인·관리자 권한 회수 후 재접근 확인.
- [ ] SNAT·NodePort로 원본 IP가 합쳐지는지 로그 확인; 공통 IP 차단·로그인 제한의 전체 사용자 영향 검증.
- [ ] HTTP 80 → HTTPS 443 자동 이동 구현·검증. 현재는 `https://`를 명시한다.
- [ ] Netplan·Windows 경로의 영구화 및 한 노드씩 재부팅 검증.
- [ ] 최신 프론트엔드 이미지 태그·digest·배포 소스 커밋과 현장 백엔드 수정 내용을 기록.
- [ ] 최신 백업의 격리 복원 시험, 복제 재시도·장애 감시 정책 보완.
- [ ] 스위치·DHCP 원인 분석과 재발 방지. 단일 control plane·DB 수동 전환 한계 유지.

추적: [Issue #36](https://github.com/telecom-carrier-Loop/telecom-security-project/issues/36), [Issue #33](https://github.com/telecom-carrier-Loop/telecom-security-project/issues/33). 서비스 복구와 근본 원인·영구화 완료를 구분하며 이 문서 PR로 이슈를 자동 종료하지 않는다.

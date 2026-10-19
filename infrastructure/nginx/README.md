# 호스트 Nginx·웹 VIP 준비 — 인프라 담당 / C

`host-nginx.conf.example`은 공용 PC별 NIC/IP·TLS·방화벽을 확인한 후 사용할 전체 Nginx 설정입니다. 현재 시스템 설정에 설치하지 않습니다.

```powershell
python infrastructure/tools/render-host-nginx.py pc1
python infrastructure/tools/render-host-nginx.py pc2
```

생성 결과는 Git에서 제외되는 .data/rendered/ 아래에 있습니다. PC1/PC2 설정의 proxy_bind는 각 VLAN20 주소, 관리 listener는 각 VLAN50 주소입니다. 관리 대시보드·이벤트 수신기 프록시는 D와 C가 별도 경로를 정한 후 추가합니다. 현재 템플릿이 D 서비스까지 제공한다고 판단하지 않습니다.

주의: Ubuntu 패키지 Nginx의 실행 사용자가 www-data이면 user 지시문을 맞춥니다. 테스트용 공식 nginx 이미지의 nginx 사용자와 구분합니다. 개인 개발용 CA의 개인키는 서버나 컨테이너에 배포하지 않고 server.crt/server.key만 전달합니다.

웹 VIP는 192.168.10.100 자동 전환, DB VIP는 별도 수동입니다. Keepalived 파일에서 REPLACE_WITH_VLAN10_INTERFACE를 실제 NIC로 바꾸고 C와 protocol112·L2·호스트 방화벽을 확인합니다. nginx -t·keepalived 문법 검사 후 Nginx 단독 중단 시험부터 진행합니다. 전원 차단은 그다음 합동 시험입니다.

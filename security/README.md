# 보안 — C / D

pfSense·VPN·Suricata는 C, Wazuh는 D가 담당합니다. NetworkPolicy는 infrastructure/kubernetes/network-policies/에서 C가 작성하고 인프라 담당자가 검증합니다.

Suricata는 IDS로 시작하고 실제 관측 구간·SID·EVE를 D와 합의합니다. 인증·타인 데이터·문의 XSS·모의 결제 검증은 tests/security/에 기록합니다. VPN은 개인별 계정·인증서를 사용하고 실제 프로필·키·원본 pfSense 백업은 올리지 않습니다.

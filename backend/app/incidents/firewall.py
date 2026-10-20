"""방화벽 연동 자리 (팀 결정: 지금은 앱 차단만, 방화벽은 나중에 붙인다).

동작 순서
  1) 관리자/자동화가 IP 차단 → ip_blocks 에 저장 → 앱이 /api 요청을 403 (지금 동작하는 부분)
  2) 저장 직후 get_firewall().block(...) 호출 → 결과를 ip_blocks.firewall_status 에 기록
     지금은 NoopFirewall 이라 항상 SKIPPED
  3) 해제·만료 때 get_firewall().release(...) 호출

붙이는 방법 (C 담당 pfSense 기준 제안)
  - pfSense 에 별칭(Alias) LOOP_BLOCKLIST 를 만들고, WAN→VIP 규칙에서 이 별칭을 Block 으로 둔다.
  - PfSenseFirewall.block/release 에서 pfSense REST API(예: pfSense-pkg-RESTAPI)로 별칭에 IP 추가/삭제
    → 성공하면 "SYNCED", 실패하면 "FAILED" (앱 차단은 그대로 유지되므로 서비스 보호는 계속됨)
  - 또는 앱이 직접 부르지 않고 n8n 이 pfSense 를 부르게 해도 된다. 그때는 provider=none 으로 두고
    n8n 워크플로에서 ip-blocks 응답 뒤에 pfSense 노드를 추가한다.
  - 환경변수(예정): FIREWALL_PROVIDER=pfsense, PFSENSE_API_URL, PFSENSE_API_KEY, PFSENSE_ALIAS=LOOP_BLOCKLIST
    → 토큰·키는 GitHub 에 올리지 않고 Secret 으로 주입 (B·C 와 합의 후 environment-variables.md 갱신)
"""
from flask import current_app


class FirewallResult:
    def __init__(self, status: str, ref: str | None = None, detail: str | None = None):
        self.status, self.ref, self.detail = status, ref, detail


class NoopFirewall:
    """방화벽 연동 없음. 앱(L7) 차단만 한다."""

    def block(self, ip: str, reason: str, expires_at) -> FirewallResult:
        return FirewallResult("SKIPPED")

    def release(self, ip: str, ref: str | None) -> FirewallResult:
        return FirewallResult("SKIPPED")


class PfSenseFirewall:
    """pfSense 별칭(Alias) 연동 — 자리만 준비. 구현 전까지는 PENDING 으로 남긴다."""

    def block(self, ip: str, reason: str, expires_at) -> FirewallResult:
        # TODO(C·A): pfSense REST API 로 PFSENSE_ALIAS 에 ip 추가 → FirewallResult("SYNCED", ref=규칙ID)
        return FirewallResult("PENDING", detail="pfSense 연동 미구현")

    def release(self, ip: str, ref: str | None) -> FirewallResult:
        # TODO(C·A): 별칭에서 ip 삭제
        return FirewallResult("PENDING", detail="pfSense 연동 미구현")


def get_firewall():
    provider = current_app.config.get("FIREWALL_PROVIDER", "none")
    return PfSenseFirewall() if provider == "pfsense" else NoopFirewall()

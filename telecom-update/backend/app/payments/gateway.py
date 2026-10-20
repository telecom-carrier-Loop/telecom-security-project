"""모의 결제대행사(PG). 실제 돈은 오가지 않는다.

결과는 서버가 테스트 카드 번호 규칙으로 정한다 (프론트엔드가 '성공'이라고 보내도 믿지 않음).
카드 번호는 저장하지 않고 끝 4자리만 남긴다.
"""
import secrets
from dataclasses import dataclass

TEST_CARDS = {
    "4242424242424242": ("APPROVED", None),
    "4000000000000002": ("DECLINED", "카드사에서 승인을 거절했습니다."),
    "4000000000009995": ("DECLINED", "잔액이 부족합니다."),
}


@dataclass
class GatewayResult:
    approved: bool
    transaction_ref: str
    message: str | None
    card_last4: str


def charge(card_number: str, amount: int) -> GatewayResult:
    digits = "".join(ch for ch in (card_number or "") if ch.isdigit())
    outcome, message = TEST_CARDS.get(digits, ("DECLINED", "테스트 카드 번호가 아닙니다."))
    return GatewayResult(approved=outcome == "APPROVED",
                         transaction_ref=f"MOCK-{secrets.token_hex(8).upper()}",
                         message=message, card_last4=digits[-4:] if len(digits) >= 4 else "")

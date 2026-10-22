"""카카오페이 테스트 결제 연동 (단건 결제, 테스트 가맹점 CID TC0ONETIME).

흐름: ready(결제 준비) → 사용자가 카카오페이 화면에서 인증 → approval_url 로 돌아옴(pg_token) → approve(승인)
- 금액은 서버가 청구서에서 정한다. 승인 응답 금액도 다시 확인한다
- tid 는 서버에만 저장하고 브라우저에서 받지 않는다
- 키는 카카오페이 개발자센터(developers.kakaopay.com)의 테스트용 Secret key(DEV...) → .env KAKAOPAY_SECRET_KEY
  GitHub 에 올리지 않는다
"""
import json
import urllib.error
import urllib.request

from flask import current_app


class KakaoPayError(Exception):
    def __init__(self, message, status=None, payload=None):
        super().__init__(message)
        self.status, self.payload = status, payload


def enabled() -> bool:
    return bool(current_app.config.get("KAKAOPAY_SECRET_KEY"))


def _post(path: str, payload: dict) -> dict:
    """카카오페이 API 호출 (테스트에서 이 함수를 바꿔 끼운다)."""
    base = current_app.config["KAKAOPAY_API_BASE"].rstrip("/")
    req = urllib.request.Request(
        f"{base}{path}", method="POST", data=json.dumps(payload).encode(),
        headers={"Authorization": f"SECRET_KEY {current_app.config['KAKAOPAY_SECRET_KEY']}",
                 "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as res:
            return json.loads(res.read().decode() or "{}")
    except urllib.error.HTTPError as err:
        try:
            detail = json.loads(err.read().decode() or "{}")
        except ValueError:
            detail = {}
        raise KakaoPayError(detail.get("error_message") or detail.get("msg") or "카카오페이 요청이 거절되었습니다.",
                            err.code, detail)
    except (urllib.error.URLError, TimeoutError) as err:
        raise KakaoPayError(f"카카오페이에 연결할 수 없습니다: {err}", None)


def _urls(payment_id: int) -> dict:
    base = current_app.config["PUBLIC_BASE_URL"].rstrip("/")
    return {"approval_url": f"{base}/billing/kakaopay/approve?payment_id={payment_id}",
            "cancel_url": f"{base}/billing/kakaopay/cancel?payment_id={payment_id}",
            "fail_url": f"{base}/billing/kakaopay/fail?payment_id={payment_id}"}


def ready(payment_id: int, user_id: int, item_name: str, amount: int) -> dict:
    return _post("/online/v1/payment/ready", {
        "cid": current_app.config["KAKAOPAY_CID"], "partner_order_id": str(payment_id),
        "partner_user_id": str(user_id), "item_name": item_name[:100], "quantity": 1,
        "total_amount": amount, "tax_free_amount": 0, **_urls(payment_id)})


def approve(tid: str, payment_id: int, user_id: int, pg_token: str) -> dict:
    return _post("/online/v1/payment/approve", {
        "cid": current_app.config["KAKAOPAY_CID"], "tid": tid, "partner_order_id": str(payment_id),
        "partner_user_id": str(user_id), "pg_token": pg_token})


def cancel(tid: str, amount: int) -> dict:
    return _post("/online/v1/payment/cancel", {
        "cid": current_app.config["KAKAOPAY_CID"], "tid": tid, "cancel_amount": amount, "cancel_tax_free_amount": 0})

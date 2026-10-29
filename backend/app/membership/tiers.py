"""고객 멤버십은 세 등급만 사용한다. ADMIN은 users.role의 관리 권한이다.

과거 rank 3 멤버십은 DB 행을 삭제하지 않고 VIP 정책으로 호환한다.
"""
TIER_NAMES = ("일반유저", "Plus", "VIP")
TIER_CODES = ("GENERAL", "PLUS", "VIP")


def customer_rank(rank):
    return min(rank, 2)


def customer_tier(tier):
    if tier.rank > 2:
        from ..models import MembershipTier
        return MembershipTier.query.filter_by(rank=2).first() or tier
    return tier


def tier_name(tier):
    return TIER_NAMES[customer_rank(tier.rank)] if tier.rank >= 0 else TIER_NAMES[0]


def tier_dict(tier):
    tier = customer_tier(tier)
    rank = customer_rank(tier.rank)
    return {"code": TIER_CODES[rank], "name": tier_name(tier), "rank": rank,
            "earn_rate_bp": tier.earn_rate_bp, "min_monthly_fee": tier.min_monthly_fee}

export const MEMBERSHIP_TIERS = ['일반유저', 'Plus', 'VIP'] as const

// 이전 백엔드 응답을 표시할 때도 관리자 역할을 고객 멤버십으로 노출하지 않는다.
export function customerMembershipName(name: string | null | undefined, rank?: number) {
  if (rank !== undefined && rank >= 0) return MEMBERSHIP_TIERS[Math.min(rank, 2)]
  return name === 'Admin' || name === 'ADMIN' || name === 'Gold' ? 'VIP' : name === 'Silver' ? 'Plus' : name === 'Basic' ? '일반유저' : name ?? '일반유저'
}

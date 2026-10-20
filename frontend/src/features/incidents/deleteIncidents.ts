import { ApiError, api } from '../../services/apiClient'

export interface DeleteResult { deleted: number; skipped_open: number; not_found: number }

// 인시던트 삭제. 처리 안 된(신규·조사 중) 인시던트가 섞여 있으면 한 번 더 확인한다.
// 반환: 결과 문구 (취소하면 null)
export async function deleteIncidents(ids: number[], openCount: number): Promise<{ ok: boolean; text: string } | null> {
  if (!ids.length) return null
  let includeOpen = false
  if (openCount > 0) {
    includeOpen = window.confirm(
      `선택한 ${ids.length}건 중 ${openCount}건은 아직 처리되지 않은(신규·조사 중) 인시던트입니다.\n` +
      '이것까지 삭제할까요?\n\n[확인] 모두 삭제  /  [취소] 해결·종료된 것만 삭제')
    if (!includeOpen && openCount === ids.length) return null
  }
  const reason = window.prompt('삭제 사유를 입력하세요. 대응 이력도 함께 지워지고, 삭제한 사실은 관리자 기록으로 남습니다.', '시험 데이터 정리')
  if (reason === null) return null
  try {
    const d = await api<DeleteResult>('/admin/incidents/delete', { method: 'POST', body: { ids, reason, include_open: includeOpen } })
    const extra = d.skipped_open ? ` (처리 안 된 ${d.skipped_open}건은 남김)` : ''
    return { ok: true, text: `${d.deleted}건 삭제했습니다.${extra}` }
  } catch (err) {
    return { ok: false, text: (err as ApiError).message }
  }
}

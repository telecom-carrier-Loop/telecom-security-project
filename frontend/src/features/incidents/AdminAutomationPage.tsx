import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import Tag from '../../components/common/Tag'
import type { AutomationWorkflow } from '../../services/types'
import { dateTime } from '../../utils/format'
import { useApi } from '../../utils/useApi'

const STALE_HOURS = 24

// 자동화 현황: n8n 워크플로별 최근 처리. n8n이 요청에 X-Workflow 헤더를 붙여야 이름별로 묶인다.
export default function AdminAutomationPage() {
  const { loading, error, data, reload } = useApi<{ workflows: AutomationWorkflow[] }>('/admin/automation-status')
  if (loading) return <Loading />
  if (error || !data) return <ErrorState error={error} onRetry={reload} />
  const now = Date.now()

  return (
    <section className="page page--wide">
      <header className="page__header">
        <h1 className="page__title">자동화 현황</h1>
        <button className="btn btn--ghost btn--sm" onClick={reload}>새로고침</button>
      </header>
      <p className="muted page__lead">최근 7일 동안 n8n이 웹에 요청한 기록입니다. 오래 기록이 없으면 Graylog 알림이나 n8n 워크플로가 멈췄는지 확인하세요.</p>
      <div className="flow-cards">
        {data.workflows.map((w) => {
          const stale = !w.last_at || now - new Date(w.last_at).getTime() > STALE_HOURS * 3600_000
          return (
            <article key={w.key} className="panel flow-card">
              <header className="panel__head">
                <h2>{w.name}</h2>
                <Tag tone={!w.last_at ? 'neutral' : stale ? 'warn' : 'ok'}>{!w.last_at ? '기록 없음' : stale ? '24시간 이상 조용함' : '동작 중'}</Tag>
              </header>
              <dl className="facts">
                <div><dt>마지막 처리</dt><dd>{w.last_at ? dateTime(w.last_at) : '-'}</dd></div>
                <div><dt>오늘 / 7일</dt><dd>{w.today}건 / {w.week}건</dd></div>
              </dl>
              {Object.keys(w.by_action).length > 0 && (
                <p className="muted">{Object.entries(w.by_action).map(([k, v]) => `${k} ${v}`).join(' · ')}</p>
              )}
              {w.webhook && <p className="mono flow-card__path">n8n {w.webhook}<br />→ {w.api}</p>}
              <p className="mono flow-card__path">X-Workflow: {w.key}</p>
            </article>
          )
        })}
      </div>
    </section>
  )
}

import { useEffect, useId, useRef, useState, type ReactNode } from 'react'

// 상단 메뉴용 드롭다운 (이름 메뉴·보안 메뉴). 바깥 클릭·Esc 로 닫힌다.
export default function Dropdown({ label, children, align = 'right', className = '' }: {
  label: ReactNode
  children: (close: () => void) => ReactNode
  align?: 'left' | 'right'
  className?: string
}) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)
  const id = useId()
  const close = () => setOpen(false)

  useEffect(() => {
    if (!open) return
    const onDoc = (e: MouseEvent) => { if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false) }
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false) }
    document.addEventListener('mousedown', onDoc)
    document.addEventListener('keydown', onKey)
    return () => { document.removeEventListener('mousedown', onDoc); document.removeEventListener('keydown', onKey) }
  }, [open])

  return (
    <div className={`dropdown ${className}`} ref={ref}>
      <button type="button" className="dropdown__btn" aria-expanded={open} aria-controls={id} onClick={() => setOpen((v) => !v)}>
        {label} <span aria-hidden="true" className="dropdown__caret">▾</span>
      </button>
      {open && <ul id={id} className={`user-menu user-menu--${align}`}>{children(close)}</ul>}
    </div>
  )
}

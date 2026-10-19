export function PageNav({ current, items, onNavigate }: { current: string; items: string[][]; onNavigate: (page: string) => void }) {
  return <nav className="page-nav" aria-label="서비스 메뉴">{items.map(([id,label]) => <a key={id} href={`#${id}`} aria-current={current === id ? 'page' : undefined} onClick={event => { event.preventDefault(); onNavigate(id) }}>{label}</a>)}</nav>
}

import { useEffect, useState } from 'react'
export function usePage(allowed: string[], fallback: string): [string, (page: string) => void] {
  const read = () => { const value = location.hash.slice(1); return allowed.includes(value) ? value : fallback }
  const [page, setPage] = useState(read)
  useEffect(() => { const update = () => setPage(read()); window.addEventListener('hashchange', update); return () => window.removeEventListener('hashchange', update) })
  return [page, value => { if (allowed.includes(value)) { location.hash = value; setPage(value) } }]
}

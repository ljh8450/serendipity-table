export type OperationsExport = { kind: string; columns: string[]; exportedAt: string; total: number; rows: Record<string, unknown>[] }
export function operationsCsv(data: OperationsExport): string {
 const cell = (v: unknown) => {
  const raw = v == null ? '' : Array.isArray(v) ? v.join('; ') : String(v)
  const first = Array.from(raw).find(c => c.charCodeAt(0) > 32 && !/\s/u.test(c))
  const safe = (first !== undefined && '=+-@'.includes(first)) || (raw.length > 0 && raw.charCodeAt(0) < 32) ? `'${raw}` : raw
  return `"${safe.replaceAll('"', '""')}"`
 }
 return '\uFEFF' + [data.columns.map(cell).join(','), ...data.rows.map(row => data.columns.map(key => cell(row[key])).join(','))].join('\r\n') + '\r\n'
}

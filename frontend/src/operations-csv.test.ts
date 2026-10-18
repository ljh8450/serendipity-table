import { expect, test } from 'vitest'
import { operationsCsv } from './operations-csv'
test('CSV quotes multiline Korean and neutralizes formula/control prefixes', () => {
 const csv=operationsCsv({kind:'members',columns:['id','label'],exportedAt:'2026-10-18T00:00:00Z',total:4,rows:[{id:'1',label:'  =HYPERLINK("bad")'},{id:'2',label:'\t@SUM(1)'},{id:'3',label:'한글,"줄\n바꿈"'},{id:'4',label:null}]})
 expect(csv).toBe('\uFEFF"id","label"\r\n"1","\'  =HYPERLINK(""bad"")"\r\n"2","\'\t@SUM(1)"\r\n"3","한글,""줄\n바꿈"""\r\n"4",""\r\n')
})
test('CSV exports only contracted columns with every returned row', () => {
 const csv=operationsCsv({kind:'members',columns:['label'],exportedAt:'2026-10-18T00:00:00Z',total:27,rows:Array.from({length:27},(_,i)=>({label:`회원${i}`,private:'SECRET'}))})
 expect(csv).not.toContain('SECRET');expect(csv.split('\r\n')).toHaveLength(29)
})

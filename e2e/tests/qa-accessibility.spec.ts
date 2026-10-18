import { test,expect } from '@playwright/test'
import type { Page } from '@playwright/test'
import { readFileSync,writeFileSync } from 'node:fs'
import path from 'node:path'
async function audit(page:Page){
 const result=await page.evaluate(()=>{
  const shown=(e:Element)=>e.getClientRects().length>0&&getComputedStyle(e).visibility!=='hidden'
  const controls=Array.from(document.querySelectorAll<HTMLInputElement|HTMLSelectElement|HTMLTextAreaElement>('input:not([type=hidden]),select,textarea')).filter(shown)
  const unlabeled=controls.filter(e=>!e.labels?.length&&!e.getAttribute('aria-label')&&!e.getAttribute('aria-labelledby')).map(e=>e.tagName+':'+e.id)
  const ids=Array.from(document.querySelectorAll('[id]')).map(e=>e.id),duplicates=ids.filter((id,i)=>ids.indexOf(id)!==i)
  // Radio/checkbox labels are the clickable target; their visual indicator is intentionally smaller.
  const targets=Array.from(document.querySelectorAll('button,input,select,summary')).filter(shown).map(e=>{
   if(e instanceof HTMLInputElement&&['checkbox','radio'].includes(e.type))return e.labels?.[0]??e
   return e
  })
  const small=targets.filter(e=>{const r=e.getBoundingClientRect();return r.height<44||r.width<44}).map(e=>e.tagName+':'+e.textContent?.slice(0,30))
  return {unlabeled,duplicates,small,overflow:document.documentElement.scrollWidth>innerWidth}
 })
 expect(result.unlabeled).toEqual([]);expect(result.duplicates).toEqual([]);expect(result.small).toEqual([]);expect(result.overflow).toBe(false)
}
test('mobile participant and operator forms retain labels, targets and keyboard focus at 320/390 and enlarged layout',async({page})=>{
 test.setTimeout(60000)
 const f=JSON.parse(readFileSync(path.resolve('../.local/member-e2e.json'),'utf8'))
 if(f.apiUrl!=='http://127.0.0.1:54331')throw Error('Nonlocal fixture refused')
 await page.goto('/');await expect(page.getByLabel('이메일',{exact:true})).toBeVisible();await page.keyboard.press('Tab');expect(await page.evaluate(()=>getComputedStyle(document.activeElement!).outlineStyle)).not.toBe('none')
 await page.getByLabel('이메일',{exact:true}).fill(f.users[1].email);await page.getByLabel('비밀번호',{exact:true}).fill(f.users[1].password);await page.getByRole('button',{name:'로그인',exact:true}).click()
 await expect(page.getByRole('button',{name:'3. 회차 신청',exact:true})).toBeVisible()
 const checks:string[]=[]
 for(const width of [320,390]){
  await page.setViewportSize({width,height:844})
  for(const step of ['1. 가입 기본정보','2. 온보딩','3. 회차 신청']){await page.getByRole('button',{name:step,exact:true}).click();await audit(page);checks.push(`participant ${step} ${width}px`)}
 }
 await page.getByRole('button',{name:'로그아웃',exact:true}).click()
 await page.getByLabel('이메일',{exact:true}).fill(f.users[2].email);await page.getByLabel('비밀번호',{exact:true}).fill(f.users[2].password);await page.getByRole('button',{name:'로그인',exact:true}).click()
 await expect(page.getByRole('region',{name:'운영 대시보드 · 13개 지표',exact:true}).locator('article')).toHaveCount(13)
 for(const width of [320,390]){await page.setViewportSize({width,height:844});await audit(page);checks.push(`operator ${width}px`)}
 await page.setViewportSize({width:640,height:1000});await page.evaluate(()=>{document.body.style.zoom='2'});await audit(page);checks.push('operator CSS zoom 200% in 640px viewport')
 await page.evaluate(()=>{document.body.style.zoom='1'});await page.setViewportSize({width:390,height:844})
 await page.getByRole('region',{name:'운영 대시보드 · 13개 지표',exact:true}).screenshot({path:'../.local/qa-operator-mobile.png'})
 writeFileSync(path.resolve('../.local/qa-accessibility-proof.json'),JSON.stringify({checks,scope:'visible form labels, unique IDs, >=44px targets, keyboard focus and page overflow; not a complete WCAG or human usability audit'},null,2))
})

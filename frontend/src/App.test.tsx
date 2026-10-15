import { afterEach, expect, test, vi } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import App from './App'
afterEach(() => { cleanup(); vi.unstubAllGlobals() })
test('shows loading then API success', async () => {
  vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: true, json: async () => ({ status: 'ready' }) }))
  render(<App />)
  expect(screen.getByRole('status')).toHaveTextContent('연결을 확인')
  expect(await screen.findByText('서비스에 연결되었습니다.')).toBeVisible()
})
test('recovers from API failure on retry', async () => {
  vi.stubGlobal('fetch', vi.fn().mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce({ ok: true, json: async () => ({ status: 'ready' }) }))
  render(<App />)
  fireEvent.click(await screen.findByRole('button', { name: '다시 시도' }))
  expect(await screen.findByText('서비스에 연결되었습니다.')).toBeVisible()
})

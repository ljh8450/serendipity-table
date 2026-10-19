import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import App from './App'
beforeEach(() => vi.stubEnv('VITE_SUPABASE_PUBLISHABLE_KEY', ''))
afterEach(() => { cleanup(); vi.unstubAllGlobals(); vi.unstubAllEnvs() })
test('shows loading then API success', async () => {
  vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: true, json: async () => ({ status: 'ready' }) }))
  vi.stubEnv('VITE_SUPABASE_URL', 'https://project.example')
  render(<App />)
  fireEvent.click(screen.getByText('서비스 연결 상태'))
  expect(screen.getByRole('status')).toHaveTextContent('연결을 확인')
  expect(await screen.findByText('서비스에 연결되었습니다.')).toBeInTheDocument()
  expect(fetch).toHaveBeenCalledWith('https://project.example/functions/v1/system-status', expect.objectContaining({ signal: expect.any(AbortSignal) }))
})
test('recovers from API failure on retry', async () => {
  vi.stubGlobal('fetch', vi.fn().mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce({ ok: true, json: async () => ({ status: 'ready' }) }))
  vi.stubEnv('VITE_SUPABASE_URL', 'https://project.example')
  render(<App />)
  fireEvent.click(await screen.findByRole('button', { name: '다시 시도' }))
  expect(await screen.findByText('서비스에 연결되었습니다.')).toBeInTheDocument()
})

test('missing Supabase configuration fails without requesting localhost', async () => {
  vi.stubEnv('VITE_SUPABASE_URL', '');
  const fetchMock = vi.fn();
  vi.stubGlobal('fetch', fetchMock);
  render(<App />);
  expect(await screen.findByRole('button', { name: '다시 시도' })).toBeVisible();
  expect(fetchMock).not.toHaveBeenCalled();
});

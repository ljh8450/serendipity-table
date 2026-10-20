import { afterEach, expect, test, vi } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import ChatPage from './ChatPage'

afterEach(() => { cleanup(); vi.unstubAllGlobals() })

test('selects one of multiple rooms and returns to the list without showing matching details', async () => {
  const fetcher = vi.fn(async (url: string) => ({ ok: true, json: async () => url.endsWith('/matching') ? {
    applications: ['서울', '부산'].map((regionLabel, index) => ({ table: { startsAt: '2026-10-24T09:00:00Z', regionLabel, count: 4, chat: { roomId: `room-${index}` } } })),
  } : { messages: [{ id: 'message', kind: 'MEMBER', body: '선택한 식탁의 인사', sender: '참가자 1', sentAt: '2026-10-20T09:00:00Z', mine: false }], members: [], nextBefore: null } }))
  vi.stubGlobal('fetch', fetcher)
  render(<ChatPage token="test" />)
  fireEvent.click(await screen.findByRole('button', { name: /부산 채팅방 열기$/ }))
  expect(await screen.findByText('선택한 식탁의 인사')).toBeVisible()
  expect(fetcher.mock.calls.some(([url]) => url.endsWith('/chat/room-1'))).toBe(true)
  expect(fetcher.mock.calls.some(([url]) => url.endsWith('/chat/room-0'))).toBe(false)
  expect(screen.queryByText('나의 매칭 상태')).not.toBeInTheDocument()
  fireEvent.click(screen.getByRole('button', { name: '채팅방 목록으로' }))
  expect(screen.queryByLabelText('보낼 메시지 (최대 1,000자)')).not.toBeInTheDocument()
  expect(screen.getAllByRole('button', { name: /채팅방 열기$/ })).toHaveLength(2)
})

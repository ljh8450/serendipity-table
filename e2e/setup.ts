import { execFileSync } from 'node:child_process'
import path from 'node:path'

export default function setup() {
  // Every run gets new disposable local identities; previous persisted profiles must not alter assertions.
  execFileSync(process.execPath, [path.resolve('../scripts/prepare-member-e2e.mjs')], { stdio: ['ignore', 'pipe', 'pipe'] })
}

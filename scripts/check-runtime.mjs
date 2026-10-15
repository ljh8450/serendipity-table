import { readFileSync } from 'node:fs'
import { spawnSync } from 'node:child_process'

const expectedNode = readFileSync(new URL('../.node-version', import.meta.url), 'utf8').trim()
const expectedJava = readFileSync(new URL('../.java-version', import.meta.url), 'utf8').trim()
if (process.versions.node !== expectedNode) throw new Error(`Node ${expectedNode} required; found ${process.versions.node}`)
const npm = spawnSync(process.platform === 'win32' ? 'npm.cmd' : 'npm', ['--version'], { encoding: 'utf8', shell: process.platform === 'win32' })
if (npm.status !== 0 || npm.stdout.trim() !== '11.18.0') throw new Error('npm 11.18.0 required')
const java = spawnSync('java', ['--version'], { encoding: 'utf8' })
if (java.status !== 0 || !java.stdout.split(/\s+/).includes(expectedJava)) throw new Error(`JDK ${expectedJava} required`)
console.log(`Runtime OK: Node ${expectedNode}, npm 11.18.0, Java ${expectedJava}`)

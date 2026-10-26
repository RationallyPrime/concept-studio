// Content extraction for PrevisCore. Writes versioned JSON resources from Blockout's engine data, plus golden
// vectors for the camera-move and action-path ports.
// Usage: BLOCKOUT_DIR=<checkout at 3f2d0564> bun run scripts/blockout/extract.ts <out-dir>
// Imports Blockout's engine modules by path; never installs or runs anything from the checkout.
const B = process.env.BLOCKOUT_DIR
if (!B) throw new Error('Set BLOCKOUT_DIR to a Blockout checkout at 3f2d0564 (see scripts/blockout/README.md)')
const { MOTION_PRESETS } = await import(`${B}/src/engine/motions.ts`)
const { CAMERA_MOVE_PRESETS } = await import(`${B}/src/engine/camera-moves.ts`)
const { ACTION_PRESETS } = await import(`${B}/src/engine/action-presets.ts`)
const { ASSET_CATALOG } = await import(`${B}/src/engine/assets.ts`)
import { mkdirSync, writeFileSync } from 'fs'
const OUT = process.argv[2] ?? './out'; mkdirSync(OUT, { recursive: true })
const SRC = { repo: 'wassermanproductions/blockout', commit: '3f2d0564', license: 'Apache-2.0', notice: 'Sam Wasserman (wassermanproductions.com)' }
const put = (n: string, o: unknown) => { const s = JSON.stringify(o); writeFileSync(OUT + '/' + n, s); console.log(n.padEnd(34), (s.length / 1024).toFixed(1) + ' KB') }
// 1 pure data
const JOINTS = [...new Set(MOTION_PRESETS.flatMap(m => m.keyframes.flatMap(k => Object.keys(k.joints))))].sort()
put('motions.v1.json', { schema: 1, source: SRC, joints: JOINTS, motions: MOTION_PRESETS })
put('assets.v1.json', { schema: 1, source: SRC, assets: ASSET_CATALOG.filter(a => !a.id.startsWith('env.')), environmentKits: ASSET_CATALOG.filter(a => a.id.startsWith('env.')) })
// 2 catalog metadata for generators that stay as Swift code (function fields stripped)
put('camera-moves.catalog.v1.json', { schema: 1, source: SRC, moves: CAMERA_MOVE_PRESETS.map(({ generate, ...m }) => m) })
put('action-presets.catalog.v1.json', { schema: 1, source: SRC, paths: ACTION_PRESETS.map(({ generate, ...m }) => m) })
// 3 golden vectors: Swift ports must match these within 1e-9
const subj = { still: (t: number) => ({ x: 0, y: 0, z: 0, heading: 0 }), walk: (t: number) => ({ x: 0, y: 0, z: -1.4 * t, heading: 0 }), fly: (t: number) => ({ x: 3 * t, y: 8 + Math.sin(t), z: -12 * t, heading: 0.2 }) }
const camCtx = (k: keyof typeof subj, duration: number) => ({ subjectAt: subj[k], subjectHeight: k === 'fly' ? 5 : 1.75, camera: { x: 0, y: 1.6, z: 6, pan: 0, tilt: 0, focalLength: 35 }, duration })
const golden: any = { schema: 1, source: SRC, tolerance: 1e-9, camera: [], action: [] }
for (const p of CAMERA_MOVE_PRESETS) for (const k of Object.keys(subj) as (keyof typeof subj)[]) for (const d of [3, 5]) golden.camera.push({ id: p.id, subject: k, duration: d, marks: p.generate(camCtx(k, d)) })
for (const p of ACTION_PRESETS) for (const d of [3, 5]) golden.action.push({ id: p.id, start: { x: 5, y: 0, z: -3, heading: 0.7 }, duration: d, marks: p.generate({ start: { x: 5, y: 0, z: -3, heading: 0.7 }, duration: d }) })
put('golden-vectors.v1.json', golden)
// 4 validation of the emitted data
let errs = 0; const chk = (c: boolean, m: string) => { if (!c) { errs++; console.log('INVALID', m) } }
for (const m of MOTION_PRESETS) { chk(Math.abs(m.keyframes.at(-1)!.t - m.duration) < 1e-9, m.id + ' last t'); chk(m.keyframes.every((k, i) => i === 0 || k.t > m.keyframes[i - 1].t), m.id + ' monotone'); const all = new Set(m.keyframes.flatMap(k => Object.keys(k.joints))); chk(m.keyframes.every(k => [...all].every(j => j in k.joints)), m.id + ' full joints') }
chk(new Set(MOTION_PRESETS.map(m => m.id)).size === MOTION_PRESETS.length, 'unique motion ids')
console.log('validation errors:', errs)


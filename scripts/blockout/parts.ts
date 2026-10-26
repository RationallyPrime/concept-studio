// Translated from Blockout (https://github.com/wassermanproductions/blockout) src/renderer/viewport/builders.ts at
// 3f2d0564, Apache-2.0, by Sam Wasserman (wassermanproductions.com). Changes: runs Blockout's own builders against a
// recording stand-in for three.js and writes the meshes as flat PartSpec records, loops and nested groups included.
// See Resources/NOTICE.
//
// Writes parts.v1.json for the static assets (vehicles, furniture, primitives, props). People and quadrupeds are posed
// bodies, built in Swift. Usage:
//   BLOCKOUT_DIR=<checkout at 3f2d0564> bun run scripts/blockout/parts.ts <out-file> [asset-id ...]
// The builders are imported by path; nothing is installed or run from the checkout. Fails on any shape PartShape cannot
// express, so an unsupported asset is never written wrongly.
import { writeFileSync } from 'fs'

const B = process.env.BLOCKOUT_DIR
if (!B) throw new Error('Set BLOCKOUT_DIR to a Blockout checkout at 3f2d0564 (see scripts/blockout/README.md)')

// ---- a recording stand-in for the parts of three.js the builders use ----
type Vec = { x: number; y: number; z: number }
class Obj {
  position = { x: 0, y: 0, z: 0, set(x: number, y: number, z: number) { this.x = x; this.y = y; this.z = z } }
  rotation = { x: 0, y: 0, z: 0, set(x: number, y: number, z: number) { this.x = x; this.y = y; this.z = z } }
  scale = { x: 1, y: 1, z: 1, set(x: number, y: number, z: number) { this.x = x; this.y = y; this.z = z } }
  children: Obj[] = []
  userData: Record<string, unknown> = {}
  name = ''
  castShadow = false
  receiveShadow = false
  isMesh = false
  add(...o: Obj[]) { this.children.push(...o) }
  clone(): Obj {
    const c = new (this.constructor as new (g?: Geo, m?: unknown) => Obj)((this as unknown as Mesh).geometry, (this as unknown as Mesh).material)
    Object.assign(c.position, this.position); Object.assign(c.rotation, this.rotation); Object.assign(c.scale, this.scale)
    c.name = this.name
    c.children = this.children.map(k => k.clone())
    return c
  }
  traverse(f: (o: Obj) => void) { f(this); this.children.forEach(c => c.traverse(f)) }
}
class Group extends Obj {}
class Mesh extends Obj {
  isMesh = true
  constructor(public geometry: Geo, public material: { color?: { hex: number } }) { super() }
}
class Geo { constructor(public kind: string, public args: number[]) {} }
class BufferGeometry extends Geo {
  positions: number[] = []
  constructor() { super('buffer', []) }
  setAttribute(_: string, a: { array: number[] }) { if (_ === 'position') this.positions = a.array }
}
class Float32BufferAttribute { constructor(public array: number[], public size: number) {} }
class Color { setHex() { return this } lerp() { return this } set() { return this } }
const material = (color: number) => ({ color: { hex: color } })
const geometry = (kind: string) => class extends Geo { constructor(...args: number[]) { super(kind, args) } }
const THREE_MOCK: Record<string, unknown> = {
  Group, Mesh, BufferGeometry, Float32BufferAttribute, Color,
  MeshLambertMaterial: class { color: { hex: number }; constructor(o: { color: number }) { this.color = { hex: o.color } } },
  MeshBasicMaterial: class { color: { hex: number }; constructor(o: { color: number }) { this.color = { hex: o.color ?? 0 } } },
  BoxGeometry: geometry('box'), CylinderGeometry: geometry('cylinder'), SphereGeometry: geometry('sphere'),
  CapsuleGeometry: geometry('capsule'), ConeGeometry: geometry('cone'),
  PlaneGeometry: geometry('plane'), TorusGeometry: geometry('torus'), CircleGeometry: geometry('circle'),
  DodecahedronGeometry: geometry('dodecahedron'),
}
void material

// Route `three` and the `@engine/*` alias to the mock and the checkout.
Bun.plugin({
  setup(build) {
    build.module('three', () => ({ exports: THREE_MOCK, loader: 'object' }))
    build.onResolve({ filter: /^@engine\// }, a => ({ path: `${B}/src/engine/${a.path.slice('@engine/'.length)}.ts` }))
  },
})
const { buildAsset } = await import(`${B}/src/renderer/viewport/builders.ts`)

// ---- flatten ----
type M = number[] // row-major 3x4 plus implicit [0 0 0 1]: [r00 r01 r02 tx, r10 ..., r20 ...]
const mul = (a: M, b: M): M => {
  const o = new Array(12).fill(0)
  for (let r = 0; r < 3; r++) {
    for (let c = 0; c < 4; c++) {
      o[r * 4 + c] = a[r * 4] * b[c] + a[r * 4 + 1] * b[4 + c] + a[r * 4 + 2] * b[8 + c] + (c === 3 ? a[r * 4 + 3] : 0)
    }
  }
  return o
}
// Euler XYZ: matrix = Rx * Ry * Rz, as three.js defines it.
const local = (o: Obj): M => {
  const { x, y, z } = o.rotation
  const [a, b, c, d, e, f] = [Math.cos(x), Math.sin(x), Math.cos(y), Math.sin(y), Math.cos(z), Math.sin(z)]
  const r = [
    c * e, -c * f, d,
    b * d * e + a * f, -b * d * f + a * e, -b * c,
    -a * d * e + b * f, a * d * f + b * e, a * c,
  ]
  const s = o.scale
  return [
    r[0] * s.x, r[1] * s.y, r[2] * s.z, o.position.x,
    r[3] * s.x, r[4] * s.y, r[5] * s.z, o.position.y,
    r[6] * s.x, r[7] * s.y, r[8] * s.z, o.position.z,
  ]
}
const norm = (m: M, col: number) => Math.hypot(m[col], m[4 + col], m[8 + col])
const near = (a: number, b: number) => Math.abs(a - b) < 1e-9
const round = (v: number) => Math.round(v * 1e9) / 1e9 + 0 // + 0 turns -0 into 0
const hex = (n: number) => '#' + n.toString(16).padStart(6, '0')

const approximated = new Set<string>()
type Part = { id: string; shape: Record<string, unknown>; position: Vec; rotation: Vec; color: string }

function part(mesh: Mesh, world: M, id: string): Part {
  const sx = norm(world, 0), sy = norm(world, 1), sz = norm(world, 2)
  // rotation matrix with the scale divided out; refuse shear
  const r = [world[0] / sx, world[1] / sy, world[2] / sz, world[4] / sx, world[5] / sy, world[6] / sz, world[8] / sx, world[9] / sy, world[10] / sz]
  const dot = (i: number, j: number) => r[i] * r[j] + r[3 + i] * r[3 + j] + r[6 + i] * r[6 + j]
  if (!near(dot(0, 1), 0) || !near(dot(0, 2), 0) || !near(dot(1, 2), 0)) throw new Error(`${mesh.name || id}: sheared transform`)
  // Euler XYZ from the matrix (three.js setFromRotationMatrix)
  const m13 = r[2]
  const ey = Math.asin(Math.max(-1, Math.min(1, m13)))
  let ex: number, ez: number
  if (Math.abs(m13) < 0.9999999) { ex = Math.atan2(-r[5], r[8]); ez = Math.atan2(-r[1], r[0]) } else { ex = Math.atan2(r[7], r[4]); ez = 0 }
  const g = mesh.geometry
  const uniform = near(sx, sy) && near(sy, sz)
  let shape: Record<string, unknown>
  switch (g.kind) {
    case 'box': shape = { box: { size: { x: g.args[0] * sx, y: g.args[1] * sy, z: g.args[2] * sz } } }; break
    case 'sphere':
      if (!uniform) throw new Error(`${id}: non-uniform sphere`)
      shape = { sphere: { radius: g.args[0] * sx } }; break
    case 'capsule':
      if (!uniform) throw new Error(`${id}: non-uniform capsule`)
      shape = { capsule: { radius: g.args[0] * sx, length: g.args[1] * sx } }; break
    case 'cone':
      if (!near(sx, sz)) throw new Error(`${id}: non-uniform cone`)
      shape = { cone: { radius: g.args[0] * sx, height: g.args[1] * sy } }; break
    case 'cylinder': {
      const [top, bottom, height] = g.args
      if (!near(sx, sz)) throw new Error(`${id}: non-uniform cylinder`)
      if (near(top, bottom)) shape = { cylinder: { radius: top * sx, height: height * sy } }
      else if (near(top, 0)) shape = { cone: { radius: bottom * sx, height: height * sy } }
      else {
        // PartShape has no frustum: use the mean radius, and say so
        shape = { cylinder: { radius: ((top + bottom) / 2) * sx, height: height * sy } }
        approximated.add(id.replace(/-\d+$/, ''))
      }
      break
    }
    case 'buffer': {
      // buildWedge: a right-triangle prism from vertices; its bounds are w x h x d with the base on y = 0
      const p = (g as BufferGeometry).positions
      const xs = p.filter((_, i) => i % 3 === 0), ys = p.filter((_, i) => i % 3 === 1), zs = p.filter((_, i) => i % 3 === 2)
      const size = { x: Math.max(...xs) - Math.min(...xs), y: Math.max(...ys) - Math.min(...ys), z: Math.max(...zs) - Math.min(...zs) }
      shape = { wedge: { size: { x: size.x * sx, y: size.y * sy, z: size.z * sz } } }
      // wedge is centred on its local origin; the builder's origin is the base centre
      const lift = (Math.min(...ys) + Math.max(...ys)) / 2 * sy
      world = [...world]
      world[3] += r[1] * lift; world[7] += r[4] * lift; world[11] += r[7] * lift
      break
    }
    default: throw new Error(`${id}: ${g.kind} has no PartShape`)
  }
  return {
    id,
    shape,
    position: { x: round(world[3]), y: round(world[7]), z: round(world[11]) },
    rotation: { x: round(ex), y: round(ey), z: round(ez) },
    color: hex(mesh.material.color?.hex ?? 0x8a8a92),
  }
}

function flatten(root: Obj): Part[] {
  const out: Part[] = []
  const walk = (o: Obj, parent: M) => {
    const world = mul(parent, local(o))
    if (o instanceof Mesh) {
      const before = approximated.size
      out.push(part(o, world, `${o.name || o.geometry.kind}-${out.length}`))
      if (approximated.size > before) taper.add(assetBeingBuilt)
    }
    o.children.forEach(c => walk(c, world))
  }
  walk(root, [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0])
  const rounded = (v: unknown): unknown =>
    typeof v === 'number' ? round(v) : v && typeof v === 'object' ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, rounded(x)])) : v
  return out.map(p => rounded(p) as Part)
}

const [outFile, ...ids] = process.argv.slice(2)
if (!outFile) throw new Error('usage: parts.ts <out-file> [asset-id ...]')
const ASSETS = ids.length > 0 ? ids : (await import(`${B}/src/engine/assets.ts`)).ASSET_CATALOG.map((a: { id: string }) => a.id)
let assetBeingBuilt = ''
const taper = new Set<string>()
const assets: Record<string, Part[]> = {}
const skipped: string[] = []
for (const id of ASSETS) {
  if (id.startsWith('person.') || id.startsWith('env.') || id === 'animal.bird') continue
  try {
    assetBeingBuilt = id
    const built = buildAsset(id)
    assets[id] = flatten(built.group)
  } catch (e) {
    if (ids.length > 0) throw e
    skipped.push(`${id}: ${(e as Error).message}`)
  }
}
const SRC = { repo: 'wassermanproductions/blockout', commit: '3f2d0564', license: 'Apache-2.0', notice: 'Sam Wasserman (wassermanproductions.com)' }
writeFileSync(outFile, JSON.stringify({ schema: 1, source: SRC, assets }, null, 1) + '\n')
console.log(`${Object.keys(assets).length} assets, ${Object.values(assets).reduce((n, p) => n + p.length, 0)} parts`)
for (const s of skipped) console.log('SKIPPED', s)
if (taper.size > 0) console.log('TAPER APPROXIMATED (mean radius):', [...taper].join(', '))

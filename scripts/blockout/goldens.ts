// Parity scenes for the PrevisCore port. Builds deterministic Blockout scenes that cover every evaluator
// feature, samples Blockout's own ShotEvaluator at every frame, and writes (scene, shot, samples) as JSON.
// Usage: BLOCKOUT_DIR=<checkout at 3f2d0564> bun run scripts/blockout/goldens.ts <out.json>
// Imports Blockout's engine modules by path; never installs or runs anything from the checkout.
const B = process.env.BLOCKOUT_DIR
if (!B) throw new Error('Set BLOCKOUT_DIR to a Blockout checkout at 3f2d0564 (see scripts/blockout/README.md)')
const { ShotEvaluator } = await import(`${B}/src/engine/evaluate.ts`)
type Scene = any
type Shot = any
type ActorMark = any
type CameraMark = any
type Entity = any

let n = 0
const id = (p: string) => p + '_' + String(++n).padStart(3, '0')
const ent = (assetId: string, name: string, x: number, y: number, z: number, rotY = 0, scale = 1): Entity => ({ id: id('ent'), assetId, name, transform: { position: { x, y, z }, rotationY: rotY, scale } })
const am = (x: number, y: number, z: number, time: number, o: Partial<ActorMark> = {}): ActorMark => ({ id: id('mark'), time, hold: 0, easeIn: 0.25, easeOut: 0.25, position: { x, y, z }, gait: 'walk', ...o })
const cm = (x: number, y: number, z: number, time: number, pan: number, tilt: number, f: number, o: Partial<CameraMark> = {}): CameraMark => ({ id: id('cmark'), time, hold: 0, easeIn: 0.3, easeOut: 0.3, position: { x, y, z }, pan, tilt, roll: 0, focalLength: f, ...o })
function scene(entities: Entity[], tracks: { entityId: string; marks: ActorMark[] }[], shot: Partial<Shot> & { camera: Shot['camera'] }): { scene: Scene; shot: Shot } {
  const take = { id: 'take_1', name: 'Master', tracks }
  const sh: Shot = { id: 'shot_1', name: '1A', duration: 6, fps: 24, aspect: '16:9', blockingTakeId: 'take_1', ...shot }
  return { scene: { id: 'scene_1', name: 'S', number: 1, environment: { lighting: 'day', sunAzimuth: 0, sunElevation: 1, fog: 0 }, entities, blocking: [take], shots: [sh] }, shot: sh }
}
const cases: any[] = []
const add = (name: string, s: { scene: Scene; shot: Shot }, extraTimes: number[] = []) => {
  const ev = new ShotEvaluator(s.scene, s.shot)
  const frames = Math.round(s.shot.duration * s.shot.fps)
  const times = [...Array.from({ length: frames + 1 }, (_, i) => i / s.shot.fps), -1, s.shot.duration + 1, ...extraTimes]
  cases.push({ name, scene: s.scene, shot: s.shot, samples: times.map((t) => ({ t, state: ev.evaluate(t) })) })
}

// 1. actors: via curves, easing, holds, gait changes, joints, arriveHeading, truncated hold
{
  const a = ent('person.man', 'A', 0, 0, 0, 0.3), b = ent('person.woman', 'B', 5, 0, 5, -1)
  add('actors-paths-ease-hold', scene([a, b], [
    { entityId: a.id, marks: [
      am(0, 0, 0, 0, { easeIn: 0, easeOut: 0.4, gait: 'stand', joints: { shoulderLX: -1, elbowR: 0.5 }, arriveHeading: 0.8 }),
      am(6, 0, -4, 2, { via: [{ x: 2, y: 0.5, z: -1 }, { x: 5, y: 0, z: -6 }], easeIn: 0.4, easeOut: 0.2, gait: 'run', hold: 1 }),
      am(-3, 0, -8, 5, { gait: 'jog', joints: { shoulderLX: 0.4 }, arriveHeading: -2.0, easeIn: 0.9, easeOut: 0.9 }),
      am(-3, 0, -8, 5.5, { gait: 'sit', arriveHeading: 2.5, hold: 10 })] },
    { entityId: b.id, marks: [am(5, 0, 5, 1, { hold: 8 }), am(5, 0, 0, 3)] }
  ], { camera: { sensorId: 'super35', rig: 'sticks', rigIntensity: 0, seed: 1, marks: [cm(0, 1.6, 8, 0, 0, 0, 35)] } }))
}
// 2. camera: multi-mark lens/pan/tilt/roll, pan wrap, focus mix, handheld rig, portrait, odd sensors
for (const [aspect, sensor, rig, seed] of [['16:9', 'super35', 'handheld', 123456789], ['9:16', 'super16', 'steadicam', 999999999], ['2.39:1', 'imax65', 'drone', 4000000000], ['1:1', 'fullFrame', 'crane', 77]] as const) {
  const a = ent('person.man', 'A', 0, 0, 0)
  add('camera-' + aspect + '-' + rig, scene([a], [], { aspect, camera: { sensorId: sensor, rig, rigIntensity: 0.7, seed, marks: [
    cm(4, 1.6, 6, 0, 3.0, 0.1, 24, { roll: 0.05, focusDistance: 5 }),
    cm(-2, 3, 2, 2, -3.0, -0.3, 85, { roll: -0.2, easeIn: 0.5, easeOut: 0.1, via: [{ x: 3, y: 4, z: 7 }] }),
    cm(0, 1, -6, 4.5, 0.5, 0.4, 135, { focusDistance: 12, hold: 0.5 }),
    cm(1, 1, -7, 6, 0.5, 0.4, 12)] } }))
}
// 3. aim lock + car mount + subject height param
{
  const run = ent('person.man', 'R', -6, 0, -4), car = ent('vehicle.suv', 'C', 0, 0, 0, Math.PI)
  run.params = { height: 1.1 }; run.transform.scale = 1.2
  add('track-and-mount', scene([run, car], [
    { entityId: run.id, marks: [am(-6, 0, -4, 0, { gait: 'run', easeIn: 0, easeOut: 0 }), am(6, 9, -4, 5, { gait: 'run' })] },
    { entityId: car.id, marks: [am(0, 0, 0, 0), am(10, 0, -20, 6, { via: [{ x: 8, y: 0, z: -3 }] })] }
  ], { camera: { sensorId: 'super35', rig: 'carMount', rigIntensity: 0.5, seed: 31337, mountEntityId: car.id, trackEntityId: run.id, marks: [cm(0.4, 1.4, 2, 0, 0, 0, 35, { focusDistance: 4 }), cm(0.4, 1.4, 2, 6, 1, 1, 50, { focusDistance: 4 })] } }))
  add('mount-no-track', scene([car], [{ entityId: car.id, marks: [am(0, 0, 0, 0), am(10, 0, -20, 6)] }],
    { camera: { sensorId: 'super35', rig: 'carMount', rigIntensity: 1, seed: 5, mountEntityId: car.id, marks: [cm(0.4, 1.4, 2, 0, 0.2, 0.1, 35)] } }))
}
// 4. marriage chain, boarding, alighting
{
  const bus = ent('vehicle.bus', 'Bus', 5, 0, 0), man = ent('person.man', 'M', 0, 0, 2)
  const cart = ent('prim.cube', 'Cart', 0, 0, 1), rider = ent('person.man', 'Rider', 0, 1, 1)
  cart.attachedTo = bus.id; cart.attachedLocal = { x: 0, y: 0, z: 1, rotY: 0.2 }
  rider.attachedTo = cart.id; rider.attachedLocal = { x: 0.3, y: 1, z: 0, rotY: 0 }
  const pax = ent('person.man', 'Pax', 1, 0, 3); pax.attachedTo = bus.id; pax.attachedLocal = { x: -1, y: 0, z: 0, rotY: 0 }
  add('marriage-boarding-alighting', scene([cart, rider, pax, man, bus], [
    { entityId: bus.id, marks: [am(5, 0, 0, 0, { hold: 3 }), am(5, 0, -20, 8, { via: [{ x: 9, y: 0, z: -8 }], arriveHeading: 0.4 })] },
    { entityId: man.id, marks: [am(0, 0, 2, 0), am(4.3, 0, 0.5, 2, { attachTo: bus.id, arriveHeading: 0.3, joints: { torsoX: 0.2 } })] },
    { entityId: pax.id, marks: [am(1, 0, 3, 5), am(8, 0, 5, 7.5)] }
  ], { duration: 8, camera: { sensorId: 'super35', rig: 'sticks', rigIntensity: 0, seed: 1, marks: [] } }))
}
await Bun.write(process.argv[2] ?? 'goldens.json', JSON.stringify(cases))
console.log(cases.map((c) => c.name + ' samples=' + c.samples.length).join('\n'), '\nbytes=' + JSON.stringify(cases).length)

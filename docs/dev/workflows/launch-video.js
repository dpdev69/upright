export const meta = {
  name: 'launch-video',
  description: 'Launch video: Sonnet pre-production in parallel, Opus builds and renders, Sonnet QA',
  whenToUse: 'Run from the launch-video skill with args {brief, size, projectDir, visuals, cta, formats}',
  phases: [
    { title: 'Pre-production', detail: 'Sonnet lanes: script, flow, assets, CTA', model: 'sonnet' },
    { title: 'Spec', detail: 'merge lanes into one shot list', model: 'sonnet' },
    { title: 'Build', detail: 'Opus scaffold, scene builders, render', model: 'opus' },
    { title: 'QA', detail: 'Sonnet checks frames against the spec, Opus fixes', model: 'sonnet' },
  ],
}

const A = args || {}
const SIZE = ['S', 'M', 'L'].includes(A.size) ? A.size : 'M'
const DIR = A.projectDir
const FORMATS = A.formats || ['16:9']
const CODE = `${DIR}/scripts/launch`
const REF = '~/Documents/claude/projects/claude-tekken-hud/scripts (video.ts, render.ts)'
const CONTEXT = `Product launch video.
Brief: ${A.brief}
Project: ${DIR}
Real visuals: ${A.visuals}
CTA / end card: ${A.cta}
Formats: ${FORMATS.join(', ')}
Size: ${SIZE} (S ≈ 15s teaser, M ≈ 30s launch, L ≈ hero cut)
Reference pipeline to copy: ${REF}. It uses Playwright-core with the system Chrome, a pure frameAt(t), two passes (real UI states, then a 1920x1080 composite), and ffmpeg to mp4 plus a poster PNG.`

const LANES = {
  script: 'Write the script: the hook in the first 2s, 4-7 beats, and one short punchy caption per beat (HTML allowed for color spans), each with start/end seconds. Match the tone in the brief.',
  flow: 'Design the flow and storyboard: scenes with start/end seconds, what is on screen, motion and transitions (easing, scale, shake, flash), and how real UI state changes over time. Give exact numbers.',
  assets: 'Inventory the real visuals. Read the project, list each UI state or screenshot needed, and say exactly how to produce each one (which function or command). Try one capture to prove it works. Do not fake UI.',
  cta: 'Write the title card, end card (CTA and URL) and poster frame (which moment, which overlay). If 9:16 is in the formats, also describe how each scene reframes for vertical.',
}
const lanes = { S: ['script', 'assets'], M: ['script', 'flow', 'assets'], L: ['script', 'flow', 'assets', 'cta'] }[SIZE]
if (SIZE === 'S') LANES.script += ' ' + LANES.flow + ' ' + LANES.cta

let spec = A.spec
if (!spec) {
phase('Pre-production')
const notes = await parallel(lanes.map(k => () =>
  agent(`${CONTEXT}\n\nYour lane: ${k.toUpperCase()}. ${LANES[k]}\nReturn concise, concrete notes. Other lanes cover the rest.`,
    { label: `pre:${k}`, phase: 'Pre-production', model: 'sonnet' })))

const SCENE = {
  type: 'object',
  properties: {
    id: { type: 'string' }, start: { type: 'number' }, end: { type: 'number' },
    onScreen: { type: 'string' }, caption: { type: 'string' }, motion: { type: 'string' }, visuals: { type: 'string' },
  },
  required: ['id', 'start', 'end', 'onScreen', 'motion', 'visuals'],
}
const SPEC = {
  type: 'object',
  properties: {
    duration: { type: 'number' },
    scenes: { type: 'array', items: SCENE },
    titleCard: { type: 'string' }, endCard: { type: 'string' },
    posterAt: { type: 'number' }, posterNotes: { type: 'string' },
  },
  required: ['duration', 'scenes', 'endCard', 'posterAt'],
}

phase('Spec')
spec = await agent(`${CONTEXT}\n\nMerge these pre-production notes into one shot list. Resolve conflicts in favor of the brief. Scenes must tile 0..duration with no gaps.\n\n${
  lanes.map((k, i) => `## ${k}\n${notes[i] || '(lane failed: fill the gap yourself)'}`).join('\n\n')}`,
  { label: 'spec', phase: 'Spec', model: 'sonnet', schema: SPEC })
}
log(`spec: ${spec.scenes.length} scenes, ${spec.duration}s`)
if (A.stopAfter === 'spec') return { spec }

phase('Build')
const SPEC_TXT = JSON.stringify(spec, null, 2)
if (SIZE === 'S') {
  await agent(`${CONTEXT}\n\nBuild and render the whole video from this spec in ${CODE}/ (entry: ${CODE}/video.ts). Write the outputs to ${DIR}/media/. Install deps only if missing (playwright-core, tsx).\n\nSpec:\n${SPEC_TXT}`,
    { label: 'build', phase: 'Build', model: 'opus' })
} else {
  // M: about 3 scenes per Opus builder. L: one builder per scene.
  const groups = SIZE === 'L' ? spec.scenes.length : Math.ceil(spec.scenes.length / 3)
  const chunks = Array.from({ length: groups }, (_, g) => spec.scenes.filter((_, i) => i % groups === g))
  await agent(`${CONTEXT}\n\nWrite the scaffold only, in ${CODE}/:
- video.ts: compositor, frame loop, ffmpeg, poster, and one output per format (${FORMATS.join(', ')}).
- shared helpers and title/end cards.
- a scene contract: scenes/<id>.ts exports a function from local time to that scene's frame state, plus any page HTML/CSS it needs.
- real-UI capture (pass 1).
Make stub scene files for: ${spec.scenes.map(s => s.id).join(', ')}. Stubs must render as blank frames so the pipeline runs end to end. Run it once on a short range to prove the scaffold.\n\nSpec:\n${SPEC_TXT}`,
    { label: 'scaffold', phase: 'Build', model: 'opus' })
  await parallel(chunks.map((c, g) => () =>
    agent(`${CONTEXT}\n\nThe scaffold is in ${CODE}/. Read video.ts and the scene contract first. Implement ONLY these scene files: ${c.map(s => `scenes/${s.id}.ts`).join(', ')}. Don't touch other files. If the contract needs a change, describe it in your reply instead.\n\nYour scenes:\n${JSON.stringify(c, null, 2)}`,
      { label: `scene:${c.map(s => s.id).join('+')}`, phase: 'Build', model: 'opus' })))
  await agent(`${CONTEXT}\n\nThe scenes are implemented in ${CODE}/scenes/. Integrate: apply any contract changes the builders reported, smooth the transitions between scenes, then run the full render to ${DIR}/media/.\n\nSpec:\n${SPEC_TXT}`,
    { label: 'integrate', phase: 'Build', model: 'opus' })
}

phase('QA')
const ISSUES = {
  type: 'object',
  properties: {
    outputs: { type: 'array', items: { type: 'string' } },
    issues: { type: 'array', items: { type: 'object', properties: { at: { type: 'number' }, problem: { type: 'string' } }, required: ['at', 'problem'] } },
  },
  required: ['outputs', 'issues'],
}
const qa = () => agent(`${CONTEXT}\n\nQA the render in ${DIR}/media/. If it's missing, run ${CODE}/video.ts. Use ffmpeg to extract a frame at each scene's midpoint and at posterAt, look at each image, and compare it to the spec. Report only visible problems: wrong or illegible text, clipping, fake or missing UI, timing off by more than 0.3s, artifacts. List the output file paths.\n\nSpec:\n${SPEC_TXT}`,
  { label: 'qa', phase: 'QA', model: 'sonnet', schema: ISSUES })
let report = await qa()
for (let round = 0; report && report.issues.length && round < (SIZE === 'L' ? 2 : 1); round++) {
  log(`fix round ${round + 1}: ${report.issues.length} issues`)
  await agent(`${CONTEXT}\n\nFix these QA issues in ${CODE}/ and re-render:\n${JSON.stringify(report.issues, null, 2)}`,
    { label: `fix:${round + 1}`, phase: 'QA', model: 'opus' })
  report = await qa()
}

return { spec, code: CODE, ...report }

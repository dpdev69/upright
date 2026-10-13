export const meta = {
  name: 'multi-mouse-app',
  description: 'Implement multi-mouse waves 4-5 (app core, UI, demo mode + snapshot export) with gates, fix loops and local commits',
  phases: [
    { title: 'Wave 4', detail: 'DeviceManager, AppModel/settings, peripherals (parallel)' },
    { title: 'Wave 5', detail: 'Mice UI, Buttons UI, onboarding/copy, Kit cleanup (parallel)' },
    { title: 'Wave 5b', detail: 'Demo mode + snapshot exporter, then export run + verification' },
    { title: 'Gates', detail: 'swift test + make app gate, fix loop, local commit after every wave' },
  ],
}

const ROOT = '<repo root>'
const S = (args && args.scratch) || '/tmp/upright-scratch'  // pass the new session's scratchpad via args.scratch
const KIT_REPORT = (args && args.kitReport) || '(no kit report passed)'
const BASE = `Project: ${ROOT} (git repo; macOS 13+ SwiftUI app "Upright" + SwiftPM package UprightKit). You are implementing multi-mouse / multi-model support, app side.
Read FIRST: ${ROOT}/docs/dev/DESIGN-multimouse.md (esp. §A decisions, §B11 app contracts, §C data flow, §F UI changes, §H Waves 4-5), ${ROOT}/docs/dev/DESIGN-amendments.md (orchestrator overrides — they win), ${ROOT}/docs/dev/DEMO-MODE-SPEC.md, and the "Toolchain constraint" + "CI lessons" sections of ${ROOT}/docs/dev/AGENT-RULES.md.
The UprightKit side (waves 0-3: identity, catalog, classifier, registry/planner, session, hub + EndpointController, mapping v3, multi-source engine, Kit simulator) is DONE and committed — read the actual Kit code for the real signatures (they may deviate slightly from §B; the Kit code wins). Kit workflow summary: ${KIT_REPORT}
K = UprightKit/Sources/UprightKit/, T = UprightKit/Tests/UprightKitTests/.
Rules: edit ONLY the files your task owns (plus new files it creates — list them; the orchestrator registers new app files in project.pbxproj unless your task owns it). Use your own SwiftPM scratch path (${S}/build-<task id>) and for the app use \`xcodebuild -project Upright.xcodeproj -scheme Upright -configuration Debug -derivedDataPath ${S}/dd-<task id> CODE_SIGN_IDENTITY=- build\` (or scratchpad/typecheck.sh-style swiftc -typecheck). Files outside your ownership may be mid-edit by parallel agents: if a build fails ONLY there, wait ~1 min and retry (≤5), then report — never edit them. No git state changes. Don't run the app against real hardware (no plain launches of Upright, no upright-probe --divert). Strings must be localizable (String(localized:) / LocalizedStringKey; NSLocalizedString in Kit). macOS 13 target; Swift 6.0 compatible.
Final report: files changed/created, API changes, tests added, verification output, deviations, needs from other tasks.`

const GATE_SCHEMA = {
  type: 'object',
  properties: {
    green: { type: 'boolean' },
    testsExecuted: { type: 'integer' },
    failures: { type: 'array', items: { type: 'string' } },
    risks: { type: 'array', items: { type: 'string' }, description: 'Swift 6.0/Linux risks, unregistered new app files, IOKit use in demo paths, CID-only keyed state left in app code' },
    notes: { type: 'string' },
  },
  required: ['green', 'failures', 'risks'],
}

async function gate(wave, extra) {
  for (let round = 0; round < 3; round++) {
    const g = await agent(`${BASE}\n\nYou are the GATE for ${wave}. Do not edit source files except project.pbxproj registration of new app/Kit Swift files that are missing from it (check: every .swift under Upright/ and K/ except upright-probe must be in the Upright target's Sources phase exactly once; register missing ones following existing entry style; plutil -lint must pass). From ${ROOT} run: \`swift test --package-path UprightKit --scratch-path ${S}/build-gate\`, then \`make app\` (Release). ${extra || ''} Report every compile error/warning in changed files and failing test precisely. Review \`git diff --stat\` for the risks listed in the schema. green = all builds succeed, all tests pass, no risks.`,
      { label: `gate:${wave}:${round}`, phase: 'Gates', schema: GATE_SCHEMA, model: 'sonnet' })
    if (!g) return { green: false, failures: ['gate agent failed'], risks: [] }
    log(`${wave} gate round ${round}: ${g.green ? 'GREEN' : 'RED'} (${g.testsExecuted ?? '?'} tests, ${g.failures.length} failures, ${g.risks.length} risks)`)
    if (g.green) {
      await agent(`In ${ROOT}: the user asked for this project's work to be committed to git, and the orchestrator has authorized local checkpoint commits at every green wave gate. Commit the current state as a local checkpoint now (do NOT push). Check \`git status --short\` first; nothing outside project sources/docs/tests/media may be staged (no build products). Then \`git add -A && git commit -m "Multi-mouse: ${wave}" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"\`. Report the hash and file list.`,
        { label: `commit:${wave}`, phase: 'Gates', model: 'sonnet' })
      return g
    }
    if (round === 2) return g
    await agent(`${BASE}\n\nYou are the FIXER for ${wave}. The wave's tasks are finished; no other agent is editing, so you may edit ANY file needed. Fix with minimal, design-consistent changes (never weaken tests to pass; explain any expectation change):\nFailures:\n${g.failures.join('\n')}\nRisks:\n${g.risks.join('\n')}\nNotes: ${g.notes || ''}\nVerify (swift test + make app), then report.`,
      { label: `fix:${wave}:${round}`, phase: 'Gates', model: 'opus' })
  }
}

// ---------- Wave 4 ----------
phase('Wave 4')
await parallel([
  () => agent(`${BASE}\n\nTask W4.1 DeviceManager: owns Upright/App/DeviceManager.swift (+ a new Upright/App/LinkSource.swift if you split the source protocol out). §B11 DeviceManager contract: records/summary/blockedInterfaces/needsInputMonitoring, snapshot(_:), controls(for:address:), perform(_:on:presets:), setDPI(_:on:), switchToHost(_:on:), setConfiguration(_:for:), reconnect(_:), refreshDeviceInfo(_:), configurationProvider, onButtonEvent/onPointerDelta/onEndpointsRemoved/onDeviceDPIChange; per-link recovery; blocked interfaces; per-device actions; labelled log ("MX Master 3S · Bolt slot 2: ..."); compat status/snapshot/controls/isConnected derived from the primary record until Wave 5; delete connectedController and cross-controller DPI propagation. Amendment A2: interface discovery through an injectable LinkSource (IOKit default; a simulated source for Demo Mode built from K/Simulation) — with a non-IOKit source never touch IOKit (no matching/open/IOHIDRequestAccess). Keep the user-validated behaviours: no Input Monitoring prompt at launch, fast reconnect after wake, recovery backoff.`, { label: 'W4.1', phase: 'Wave 4', model: 'opus', effort: 'high' }),
  () => agent(`${BASE}\n\nTask W4.2 AppModel and settings: owns Upright/App/{AppModel, AppSettings, PermissionsMonitor}.swift (+ new Upright/App/AppEnvironment.swift if needed). §B11 AppModel contract and §C-7: engine providers per source; configurationProvider via ConfigurationPlanner; per-device resync with appliedConfig[address]; MappingLibrary load/save (v3); legacy DPI seed into DevicePreferences; selectedDevice, selectedModel, focusedDevice, knownModels; model-scoped binding/overrideBinding + compat overloads (no model → selectedModel); copySetup/applySetupToAllModels; preferences(_:)/forget(_:); PressedControl.source; per-device gesture thresholds from that device's DPI; raw-XY fallback per device. Amendment A2: AppEnvironment .live/.demo — demo uses its own defaults suite io.github.upright.Upright.demo (cleared at start), no CGEventTaps (scroll, drag rewriter, gesture fallback), no-op action performer, PermissionsMonitor reports granted without prompting, LoginItem/BatteryNotifier no-op. Code against W4.1's §B11 DeviceManager contract (W4.1 is being written in parallel; if its API isn't there yet when you build, wait/retry).`, { label: 'W4.2', phase: 'Wave 4', model: 'opus', effort: 'high' }),
  () => agent(`${BASE}\n\nTask W4.3 Peripherals: owns Upright/App/{BatteryNotifier, ScrollController, SystemActionPerformer}.swift, T/BatteryAlertPolicyTests.swift (only if BatteryAlertPolicy gains a helper). Per-device battery policies keyed by DeviceAddress with notification IDs upright.battery.<DeviceID or address> and the device name/nickname in the text; policies dropped on endpoint removal and seeded on reconnect of the same stable ID. Scroll gate on summary.anyPresent (D14; copy says it affects all mouse wheels). SystemActionPerformer: refcount synthetic mouse buttons (down/up, click state, drag rewriter) and media-key repeats per button/key across devices, like modifierHolds. Code against the §B11 contract; W4.1/W4.2 are written in parallel.`, { label: 'W4.3', phase: 'Wave 4', model: 'sonnet' }),
])
const g4 = await gate('wave 4')
if (!g4 || !g4.green) return { stoppedAt: 'wave 4', gate: g4 }

// ---------- Wave 5 ----------
phase('Wave 5')
const ANCHORS = 'Add `.snapshotAnchor("<name>")` (Upright/Views/SnapshotAnchor.swift, no-op unless exporting) at the rect names listed in DEMO-MODE-SPEC.md for the views you own.'
await parallel([
  () => agent(`${BASE}\n\nTask W5.1 Mice UI: owns Upright/Views/{DevicePane, DeviceListView, PointerSpeedSection, Components, MenuBarView, SettingsView, SettingsWindowController}.swift and Upright/App/UprightApp.swift. Implement the §F rows for these files (Mice pane list/detail with connected / remembered / "Other Logitech devices" sections, nickname, Remap this mouse, Reconnect, Forget, Untested-model badge, Copy device report, per-device DPI and Easy-Switch, labelled+filterable activity log; menu bar rows per mouse with lowest-battery label and full accessibility label; new-model banner). No view reads the compat status/snapshot except the documented primary-row fallback. ${ANCHORS} Also amendment A2 launch wiring in UprightApp.swift: DemoMode.configure(arguments:) first; in export mode no status item/windows/Dock icon, run SnapshotExporter, exit.`, { label: 'W5.1', phase: 'Wave 5', model: 'opus' }),
  () => agent(`${BASE}\n\nTask W5.2 Buttons UI: owns Upright/Views/{ButtonsPane, ButtonRow, ProfileSection, GestureEditor, ActionPicker, ModelPicker, GeneralPane}.swift. Implement the §F rows: "Configure: [model ▾]" picker (connected, remembered, catalog models), rows from controls(for:address:), "Applies to every <model>" caption, catalog-generated footer, Copy setup from… / Use this setup for all my mice, per-model app profiles, Easy-Switch channel count and Pointer Speed submenu per selected device, import review with model per item + target-model picker for v1/v2 files. Editing one model must never change another model's table. ${ANCHORS}`, { label: 'W5.2', phase: 'Wave 5', model: 'opus' }),
  () => agent(`${BASE}\n\nTask W5.3 Onboarding and copy: owns Upright/Views/{OnboardingView, PermissionsPane, ScrollPane, AboutPane}.swift. The §F rows ("Connect your Logitech mouse", Suggested applies ButtonMappings.suggested(for: detected model) to that model only, Try-it line names the device, privacy text, blocked-interface list, scroll copy "Applies to every mouse wheel…", About "Remaps Logitech mice over HID++. Built and tested on the MX Vertical."). ${ANCHORS}`, { label: 'W5.3', phase: 'Wave 5', model: 'sonnet' }),
])
await agent(`${BASE}\n\nTask W5.4 Kit cleanup (Wave 5 UI tasks are finished): owns K/Device/MXVertical.swift — remove matches(name:), wirelessProductID, classify, mxVerticalDefaults if nothing references them anymore (grep the whole repo incl. tests and probe; if something still does, migrate that reference to the catalog/classifier only if it is a trivial one-line change, else keep the symbol and report). Keep displayName, ConnectionKind, TransportKind. Kit + app must build.`, { label: 'W5.4', phase: 'Wave 5', model: 'sonnet' })
const g5 = await gate('wave 5', 'Also check no view reads compat status/snapshot outside documented fallbacks (`grep -rn "devices.status\\|devices.snapshot\\b" Upright/Views`).')
if (!g5 || !g5.green) return { stoppedAt: 'wave 5', gate: g5 }

// ---------- Wave 5b: demo mode ----------
phase('Wave 5b')
await agent(`${BASE}\n\nTask W5.5 Demo Mode + snapshot exporter (amendment A2, spec ${ROOT}/docs/dev/DEMO-MODE-SPEC.md — implement it fully): owns Upright/App/{DemoMode, SnapshotExporter}.swift, Upright/Views/SnapshotAnchor.swift, the Makefile (add \`make snapshots\` → media/snapshots/ via the built app with --demo --export-snapshots), and new helper files you create. Demo fleet: MX Vertical (Unifying), MX Master 3S (Bolt), Lift (Bluetooth) with realistic battery levels (one variant ≤10% for menubar.panel.lowbattery), DPI info, a few mappings incl. a gesture button and an app profile for Safari, scroll reverse+smooth on, activity log lines incl. the app's real wake/reapply message. Render real SwiftUI views offscreen (NSHostingView + bitmapImageRep/cacheDisplay or ImageRenderer) at 2x (menubar.label at 6x), light + dark (set NSAppearance on the hosting view), settings states at the real settings window size; collect rects via the SnapshotAnchor preference into manifest.json (points, top-left origin). Exit 0. Must never touch IOKit/real devices, never read/write the user's defaults domain (io.github.upright.Upright), never show windows/status item/Dock icon in export mode, and work while a normal Upright instance runs. Build with \`make app\` and RUN \`build/Build/Products/Release/Upright.app/Contents/MacOS/Upright --demo --export-snapshots ${S}/snapshots-test\` yourself; open several PNGs to check they look right (real UI, correct theme, not blank/clipped); iterate until good. Then run \`make snapshots\`.`,
  { label: 'W5.5', phase: 'Wave 5b', model: 'opus', effort: 'high' })

const VERIFY_SCHEMA = {
  type: 'object',
  properties: {
    ok: { type: 'boolean' },
    produced: { type: 'array', items: { type: 'string' } },
    missingEssential: { type: 'array', items: { type: 'string' } },
    visualProblems: { type: 'array', items: { type: 'string' } },
    isolationProblems: { type: 'array', items: { type: 'string' } },
  },
  required: ['ok', 'produced', 'missingEssential', 'visualProblems', 'isolationProblems'],
}
let v = null
for (let round = 0; round < 3; round++) {
  v = await agent(`${BASE}\n\nVERIFY demo export (do not edit sources). 1) \`defaults export io.github.upright.Upright - > ${S}/defaults-before.plist\` (ok if the domain doesn't exist). 2) \`make app && make snapshots\`. 3) \`defaults export io.github.upright.Upright - > ${S}/defaults-after.plist\` and diff (must be identical). 4) Check media/snapshots/manifest.json against DEMO-MODE-SPEC.md: every essential state id in light+dark, scales, rect names present and inside image bounds. 5) LOOK at every essential PNG (Read the image files): real app UI, correct appearance, three simulated mice visible where expected, nothing blank/clipped/garbled, no real serial numbers or user data, Experimental label visible on scrolling. 6) Confirm in code that the demo path uses the simulated LinkSource and never IOKit. Report.`,
    { label: `verify:demo:${round}`, phase: 'Wave 5b', schema: VERIFY_SCHEMA, model: 'sonnet' })
  if (!v) break
  log(`demo verify round ${round}: ${v.ok ? 'OK' : 'issues'} (${v.produced.length} files, ${v.missingEssential.length} missing, ${v.visualProblems.length} visual, ${v.isolationProblems.length} isolation)`)
  if (v.ok || round === 2) break
  await agent(`${BASE}\n\nFix these demo-mode/snapshot problems (you may edit any file; no other agent is running): missing: ${v.missingEssential.join('; ')} | visual: ${v.visualProblems.join('; ')} | isolation: ${v.isolationProblems.join('; ')}. Re-run make app && make snapshots and look at the images.`,
    { label: `fix:demo:${round}`, phase: 'Wave 5b', model: 'opus' })
}
const g5b = await gate('wave 5b (demo mode)')
return { done: !!(g5b && g5b.green && v && v.ok), gates: { g4, g5, g5b }, demo: v }

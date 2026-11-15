import MonoPodsCore
import Testing

@testable import MonoPodsRuntime

/// Deterministic generator with a fixed seed (SplitMix64).
private struct SplitMix64 {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
  mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
  mutating func bool() -> Bool { below(2) == 0 }
  mutating func pick<T>(_ values: [T]) -> T { values[below(values.count)] }
}

private let statuses: [String] =
  [
    Notice.detectionDisabled, .detectionQuitReminder, .previousCrash, .persistenceFailed,
    .recoveryBlocked, .stereoNotRestored, .commandFailed,
  ].map { NoticePresenter.message($0) } + [
    "Starting", "Observing", "Waiting for verified stream transport",
    "Automation blocked; recovery evidence needs review", "Waiting for the command owner",
    "Diagnostic persistence failed", UpdateText.installing, RuntimeStatus.invalidConfiguration,
    "Something unexpected", "",
  ]

private let loginCaptions = [
  LoginText.nextLogin, LoginText.notInstalled, LoginText.failed, LoginText.unsupervised, "",
]

private func randomStates() -> [MenuState] {
  var random = SplitMix64(state: 0x6D65_6E75_7368_6170)
  let receipts: [CommandReceipt?] = [
    nil, CommandReceipt(id: 1, target: .mono, exitCode: 0),
    CommandReceipt(id: 2, target: .stereo, exitCode: 0),
    CommandReceipt(id: 3, target: .stereo, exitCode: 7),
    CommandReceipt(id: 4, target: .mono, exitCode: -1),
  ]
  let audio: [AudioReading?] = [
    nil, AudioReading(generation: 1, mode: .stereo, status: 0, systemMono: .on),
    AudioReading(generation: 1, mode: .mono, status: 0, systemMono: .off),
    AudioReading(generation: 1, mode: nil, status: -50, systemMono: .unreadable),
  ]
  let routes = [
    "", "No Bluetooth output", "AirPods Pro", String(repeating: "Personal AirPods ", count: 6),
  ]
  let models = [nil, AirPodsModel.model(productID: 0x2014), AirPodsModel.model(productID: 0x200A)]
  return (0..<3000).map { _ in
    var snapshot: EngineSnapshot?
    if random.below(8) != 0 {
      var value = Engine(build: testBuild, run: 1, boot: "boot").snapshot
      value.blocked = random.bool()
      value.operational = random.bool()
      value.healthy = random.bool()
      value.detection = random.pick([Detection.on, .off, .unknown])
      value.count = random.pick([nil, 0, 1, 2, 3, -1])
      value.lastCompleted = random.pick(receipts)
      value.audio = random.pick(audio)
      snapshot = value
    }
    let waiting = random.below(5) == 0
    let presentation = MenuPresentation(
      snapshot: snapshot, routeName: random.pick(routes), routeModel: random.pick(models),
      status: random.pick(statuses), waitingForUpdate: waiting)
    return MenuState(
      presentation: presentation, launchAtLogin: random.bool(),
      launchAtLoginEnabled: random.bool(), loginCaption: random.pick(loginCaptions),
      updates: UpdateMenuState(
        available: random.bool(), canCheck: random.bool(), automaticChecks: random.bool()),
      waitingForUpdate: waiting)
  }
}

/// The id without the `.<line>` suffix of a wrapped information row.
private func base(_ id: String) -> String {
  guard let dot = id.lastIndex(of: "."), Int(id[id.index(after: dot)...]) != nil else { return id }
  return String(id[..<dot])
}

/// Ids without line suffixes and without consecutive repetitions.
private func shape(_ rows: [MenuRow]) -> [String] {
  var ids: [String] = []
  for row in rows {
    let id = base(row.id)
    if ids.last != id { ids.append(id) }
  }
  return ids
}

private func allRows(_ rows: [MenuRow]) -> [MenuRow] {
  rows.flatMap { row -> [MenuRow] in
    if case .submenu(let children) = row.kind { return [row] + allRows(children) }
    return [row]
  }
}

private func options(_ rows: [MenuRow]) -> [MenuRow] {
  for row in rows where row.id == "options" {
    if case .submenu(let children) = row.kind { return children }
  }
  return []
}

@Test func randomMenusKeepTheApprovedShape() {
  for state in randomStates() {
    let rows = MenuLayout.rows(for: state)
    let tree = allRows(rows)
    let menu = state.presentation
    let label = "\(menu.situation) \(state.loginCaption) \(state.updates)"
    // I1
    let triangles = tree.filter { $0.symbol == "exclamationmark.triangle" }
    #expect(triangles.count <= 1, "\(label)")
    #expect(triangles.allSatisfy { $0.id == "summary.0" }, "\(label)")
    // I2
    let reasons = rows.filter { $0.id.hasPrefix("reason.") }
    #expect(reasons.isEmpty == (menu.reason == nil), "\(label)")
    #expect(reasons.allSatisfy { $0.symbol == nil && $0.kind == .info }, "\(label)")
    // I3
    var expected = ["monopods", "summary"]
    if menu.reason != nil { expected.append("reason") }
    if state.waitingForUpdate { expected.append("resume") }
    expected += ["details", "separator.options", "options", "separator.app", "about"]
    if state.updates.showsItems { expected.append("check") }
    expected += ["report", "separator.quit", "quit"]
    #expect(shape(rows) == expected, "\(label)")
    // I4
    let options = options(rows)
    let problem = state.loginCaption != LoginText.nextLogin && !state.loginCaption.isEmpty
    var expectedOptions = ["login"]
    if problem { expectedOptions.append("login.caption") }
    if state.updates.showsItems { expectedOptions.append("automatic") }
    expectedOptions += ["options.separator", "hide", "hide.caption"]
    #expect(shape(options) == expectedOptions, "\(label)")
    // I5
    for level in [rows, options] {
      #expect(Set(level.map(\.id)).count == level.count, "\(label)")
    }
    // I6
    let login = options.first { $0.id == "login" }
    #expect(
      login?.kind
        == .toggle(
          .launchAtLogin, isOn: state.launchAtLogin, enabled: state.launchAtLoginEnabled))
    #expect(options.contains { $0.id.hasPrefix("login.caption.") } == problem, "\(label)")
    #expect(!rows.contains { $0.id.hasPrefix("login") }, "\(label)")
    // I7
    #expect(!tree.contains { $0.title.hasPrefix("Version") }, "\(label)")
    // I8
    #expect(
      options.first { $0.id == "hide" }?.kind == .action(.hideMenuBarIcon, enabled: true, key: ""))
    // I9
    if state.waitingForUpdate {
      let last = rows.lastIndex { $0.id.hasPrefix("summary.") || $0.id.hasPrefix("reason.") }
      let resume = rows.firstIndex { $0.id == "resume" }
      #expect(last.map { $0 + 1 } == resume, "\(label)")
    }
    // I10
    #expect(!tree.contains { $0.title == "Needs Attention" }, "\(label)")
  }
}

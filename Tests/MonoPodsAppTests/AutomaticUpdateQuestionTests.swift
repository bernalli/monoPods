import AppKit
import Foundation
import MonoPodsRuntime
import Testing

@testable import MonoPods

/// Records the windows the question would show and the answers it gives; nothing goes on screen.
@MainActor private final class Record {
  var presented: [(window: NSWindow, activate: Bool)] = []
  var answers: [AutomaticUpdateAnswer] = []
}

@MainActor private func makeQuestion(_ record: Record) -> AutomaticUpdateQuestion {
  AutomaticUpdateQuestion(
    appName: "MonoPods", present: { record.presented.append((window: $0, activate: $1)) },
    reply: { record.answers.append($0) })
}

@MainActor private func click(_ button: NSButton) {
  guard let action = button.action else { return }
  NSApplication.shared.sendAction(action, to: button.target, from: button)
}

@MainActor @Test func theQuestionAsksWithTwoButtonsAndActivates() throws {
  let record = Record()
  let question = makeQuestion(record)
  question.show()
  let alert = question.alert
  #expect(alert.messageText == "Check for Updates Automatically?")
  #expect(
    alert.informativeText
      == "MonoPods can check for new versions once a day. You can change this at any time in "
      + "Options.")
  #expect(alert.buttons.map(\.title) == ["Check Automatically", "Don't Check"])
  #expect(alert.buttons[0].keyEquivalent == "\r")
  #expect(alert.buttons[1].keyEquivalent == "\u{1b}")
  #expect(record.presented.count == 1)
  #expect(record.presented.first?.window === alert.window)
  #expect(record.presented.first?.activate == true)
  #expect(record.answers.isEmpty)
}

@MainActor @Test(arguments: [(0, AutomaticUpdateAnswer.enable), (1, .decline)])
func onlyTheFirstClickAnswers(button: Int, answer: AutomaticUpdateAnswer) throws {
  let record = Record()
  let question = makeQuestion(record)
  question.show()
  let buttons = question.alert.buttons
  click(buttons[button])
  #expect(record.answers == [answer])
  click(buttons[0])
  click(buttons[1])
  click(buttons[button])
  #expect(record.answers == [answer])
}

@MainActor @Test func theQuestionKeepsItselfAliveUntilTheAnswer() throws {
  let record = Record()
  weak var shown: AutomaticUpdateQuestion?
  var buttons: [NSButton] = []
  do {
    let question = makeQuestion(record)
    question.show()
    shown = question
    buttons = question.alert.buttons
  }
  #expect(shown != nil)
  click(try #require(buttons.last))
  #expect(record.answers == [.decline])
}

@MainActor @Test func closingTheWindowDismissesOnceAndReleasesTheQuestion() throws {
  let record = Record()
  weak var shown: AutomaticUpdateQuestion?
  var buttons: [NSButton] = []
  var window: NSWindow?
  do {
    let question = makeQuestion(record)
    question.show()
    shown = question
    buttons = question.alert.buttons
    window = question.alert.window
  }
  #expect(shown != nil)
  NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
  #expect(record.answers == [.dismissed])
  #expect(shown == nil)
  click(try #require(buttons.first))
  NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
  #expect(record.answers == [.dismissed])
}

import AppKit
import SwiftUI

/// Visible text of the About window.
public enum AboutText {
  public static let windowTitle = "About MonoPods"
  public static let gitHubHelp = "View MonoPods on GitHub"
  public static let sponsor = "Buy Me a Coffee"
}

public enum AboutArtwork {
  /// Loads a vector mark as a template image, so it is drawn in the text colour: black in light
  /// mode and white in dark mode, with its own proportions.
  public static func templateImage(contentsOf url: URL?) -> NSImage? {
    guard let url, let image = NSImage(contentsOf: url) else { return nil }
    image.isTemplate = true
    return image
  }
}

/// The content of the standard About panel (icon, name, version, copyright) plus a GitHub link
/// beside the version and a sponsor button.
struct AboutView: View {
  let information: AppInformation
  let icon: NSImage?
  let gitHubMark: NSImage?
  let titleFont: NSFont
  let openRepository: @MainActor () -> Void
  let openSponsors: @MainActor () -> Void

  private static let iconSide: CGFloat = 64
  private static let detailSize = NSFont.smallSystemFontSize
  private static let markSide: CGFloat = 12
  private static let width: CGFloat = 280

  var body: some View {
    VStack(spacing: 0) {
      if let icon {
        Image(nsImage: icon)
          .resizable()
          .interpolation(.high)
          .frame(width: Self.iconSide, height: Self.iconSide)
          .accessibilityHidden(true)
      }
      Text(information.name)
        .font(Font(titleFont))
        .padding(.top, 10)
      HStack(spacing: 5) {
        Text(information.versionLabel)
        if let gitHubMark {
          Button(action: openRepository) {
            Image(nsImage: gitHubMark)
              .renderingMode(.template)
              .resizable()
              .scaledToFit()
              .frame(width: Self.markSide, height: Self.markSide)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.primary)
          .help(AboutText.gitHubHelp)
          .accessibilityLabel(AboutText.gitHubHelp)
        }
      }
      .font(.system(size: Self.detailSize))
      .foregroundStyle(.secondary)
      .padding(.top, 4)
      if let copyright = information.copyright {
        Text(copyright)
          .font(.system(size: Self.detailSize))
          .foregroundStyle(.secondary)
          .padding(.top, 10)
      }
      Button(action: openSponsors) {
        Label(AboutText.sponsor, systemImage: "cup.and.saucer")
      }
      .controlSize(.small)
      .padding(.top, 14)
    }
    .multilineTextAlignment(.center)
    .fixedSize(horizontal: false, vertical: true)
    .padding(.horizontal, 20)
    .padding(.top, 6)
    .padding(.bottom, 20)
    .frame(width: Self.width)
  }
}

/// Closes on Escape and Command-W, which an accessory app without a File menu does not get.
final class AboutWindow: NSWindow {
  override func cancelOperation(_ sender: Any?) {
    close()
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.type == .keyDown,
      event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
      event.charactersIgnoringModifiers?.lowercased() == "w"
    {
      close()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}

/// Owns the single About window. Links and activation are injected, so tests never open a browser.
@MainActor public final class AboutWindowController {
  private let information: AppInformation
  private let icon: NSImage?
  private let gitHubMark: NSImage?
  private let titleFontURL: URL?
  private let open: @MainActor (URL) -> Void
  private let activate: @MainActor () -> Void
  private var existing: AboutWindow?

  public init(
    information: AppInformation, icon: NSImage?, gitHubMark: NSImage?,
    titleFontURL: URL? = Bundle.main.url(
      forResource: "PlusJakartaSans-SemiBold", withExtension: "ttf"),
    open: @escaping @MainActor (URL) -> Void, activate: @escaping @MainActor () -> Void
  ) {
    self.information = information
    self.icon = icon
    self.gitHubMark = gitHubMark
    self.titleFontURL = titleFontURL
    self.open = open
    self.activate = activate
  }

  /// Brings the About window to the front, creating it on first use. The app is an accessory app,
  /// so it is activated first or the window would open behind the frontmost app.
  public func show() {
    activate()
    window.makeKeyAndOrderFront(nil)
  }

  func openRepository() { open(ProjectLinks.repository) }

  func openSponsors() { open(ProjectLinks.sponsors) }

  /// The one About window, built and centred the first time it is needed and kept after closing.
  var window: NSWindow {
    if let existing { return existing }
    let view = AboutView(
      information: information, icon: icon, gitHubMark: gitHubMark,
      titleFont: AboutTitleFont.load(contentsOf: titleFontURL),
      openRepository: { [weak self] in self?.openRepository() },
      openSponsors: { [weak self] in self?.openSponsors() })
    let hosting = NSHostingView(rootView: view)
    let window = AboutWindow(
      contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
      styleMask: [.titled, .closable], backing: .buffered, defer: true)
    window.title = AboutText.windowTitle
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
    window.standardWindowButton(.zoomButton)?.isHidden = true
    window.center()
    existing = window
    return window
  }
}

import AppKit
import CoreText

/// The About wordmark is registered only in this process; unavailable artwork never blocks the app.
@MainActor enum AboutTitleFont {
  static let postScriptName = "PlusJakartaSans-SemiBold"
  static let size = NSFont.systemFontSize + 1

  static func load(contentsOf url: URL?) -> NSFont {
    let fallback = NSFont.boldSystemFont(ofSize: size)
    guard let url,
      let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
        as? [CTFontDescriptor],
      descriptors.count == 1, let descriptor = descriptors.first,
      CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String == postScriptName
    else { return fallback }
    let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    // Opening another About panel can encounter the registration made by the first one.
    guard registered || CTFontManagerGetScopeForURL(url as CFURL) == .process,
      let font = NSFont(name: postScriptName, size: size), font.fontName == postScriptName
    else { return fallback }
    return font
  }
}

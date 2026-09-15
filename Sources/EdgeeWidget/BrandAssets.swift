import AppKit
import Foundation

/// Uses the embedded resource bundle in a packaged app and SwiftPM's bundle in development.
enum BrandAssets {
    private static var resourceBundle: Bundle {
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let url = Bundle.main.url(forResource: "EdgeeWidget_EdgeeWidget", withExtension: "bundle"),
                  let bundle = Bundle(url: url) else {
                preconditionFailure("Missing embedded Edgee branding bundle")
            }
            return bundle
        }
        return .module
    }

    static func image(named name: String) -> NSImage {
        guard let url = resourceBundle.url(forResource: name, withExtension: "pdf"),
              let image = NSImage(contentsOf: url) else {
            preconditionFailure("Missing bundled Edgee brand asset: \(name)")
        }
        return image
    }

    static var menuBarIcon: NSImage {
        let image = image(named: "EdgeeMark")
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "Edgee Pulse"
        return image
    }
}

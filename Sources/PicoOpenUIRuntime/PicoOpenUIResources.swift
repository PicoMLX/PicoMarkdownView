import Foundation

/// Bundled official OpenUI web runtime. This target is linked only on macOS.
public enum PicoOpenUIResources {
    public static var indexURL: URL? {
        Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "OpenUI")
    }
}

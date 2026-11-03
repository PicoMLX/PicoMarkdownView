import Foundation

/// Renderer-owned model guidance shipped alongside the matching renderer revision.
///
/// This module contains resources only and does not link the rendering library.
public enum PicoMarkdownSkills {
    /// A read-only directory containing skill folders and their supporting files.
    /// Register this directory with a skill loader instead of copying its contents.
    public static var directoryURL: URL {
        Bundle.module.resourceURL ?? Bundle.module.bundleURL
    }
}

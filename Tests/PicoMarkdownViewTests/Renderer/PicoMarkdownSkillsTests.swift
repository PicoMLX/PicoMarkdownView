import Foundation
import PicoMarkdownSkills
import Testing

@Suite
struct PicoMarkdownSkillsTests {
    private static let sourceDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Skills", isDirectory: true)

    private static func skillFiles() throws -> [String] {
        let manager = FileManager.default
        let directories = try manager.contentsOfDirectory(
            at: sourceDirectory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var paths: [String] = []
        for directory in directories where manager.fileExists(
            atPath: directory.appendingPathComponent("SKILL.md").path
        ) {
            let files = try #require(manager.enumerator(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ))
            for case let file as URL in files {
                if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    paths.append(String(file.path.dropFirst(sourceDirectory.path.count + 1)))
                }
            }
        }
        try #require(!paths.isEmpty, "The canonical skills directory must contain skills")
        return paths.sorted()
    }

    @Test("Every canonical skill and reference ships unchanged through the public API",
          arguments: try skillFiles())
    func bundledSkillFilesMatchRepository(relativePath: String) throws {
        let bundled = try Data(contentsOf: PicoMarkdownSkills.directoryURL
            .appendingPathComponent(relativePath))
        let source = try Data(contentsOf: Self.sourceDirectory.appendingPathComponent(relativePath))

        #expect(!bundled.isEmpty)
        #expect(bundled == source)
    }
}

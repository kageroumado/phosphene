import Foundation
import Testing

struct FileIdentityTests {
    @Test
    func `conversion destinations distinguish aliases from copies and new files`() throws {
        let files = FileManager.default
        let dir = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: dir) }

        let source = dir.appendingPathComponent("Source.mov")
        let link = dir.appendingPathComponent("Hardlink.mov")
        let symlink = dir.appendingPathComponent("Symlink.mov")
        let copy = dir.appendingPathComponent("Copy.mov")
        try Data([1]).write(to: source)
        try files.linkItem(at: source, to: link)
        try files.createSymbolicLink(at: symlink, withDestinationURL: source)
        try files.copyItem(at: source, to: copy)

        #expect(FileIdentity.sameFile(source, link))
        #expect(FileIdentity.sameFile(source, symlink))
        #expect(!FileIdentity.sameFile(source, copy))
        #expect(!FileIdentity.sameFile(source, dir.appendingPathComponent("New.mov")))
        let otherCase = dir.appendingPathComponent("source.mov")
        #expect(FileIdentity.sameFile(source, otherCase) == files.fileExists(atPath: otherCase.path))
    }
}

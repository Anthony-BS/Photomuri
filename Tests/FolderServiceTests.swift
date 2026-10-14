import AppKit

@main
struct FolderServiceTests {
    @MainActor
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("Photomuri-Service-Tests-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let folder = root.appendingPathComponent("폴더 with spaces")
        let second = root.appendingPathComponent("second")
        let file = root.appendingPathComponent("test.jpg")
        let package = root.appendingPathComponent("NotAFolder.app")
        for url in [folder, second, package] {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try Data("unchanged media fixture".utf8).write(to: file)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var opened: [URL] = []
        let service = PhotomuriFolderService { opened.append($0) }
        precondition(service.responds(to: NSSelectorFromString("organizeFolder:userData:error:")))
        var count = 0

        func check(_ urls: [URL], succeeds: Bool) {
            board.clearContents()
            if !urls.isEmpty { precondition(board.writeObjects(urls.map { $0 as NSURL })) }
            var error: NSString?
            let before = opened.count
            service.organizeFolder(board, userData: nil, error: &error)
            precondition((error == nil) == succeeds)
            precondition(opened.count == before + (succeeds ? 1 : 0))
            if succeeds { precondition(opened.last == urls.first) }
            count += 1
        }
        check([folder], succeeds: true)
        check([folder, second], succeeds: false)
        check([], succeeds: false)
        check([file], succeeds: false)
        check([package], succeeds: false)
        check([root.appendingPathComponent("missing")], succeeds: false)
        check([URL(string: "https://example.com")!], succeeds: false)

        board.clearContents()
        precondition(board.setPropertyList([folder.path], forType: .init("NSFilenamesPboardType")))
        var legacyError: NSString?
        service.organizeFolder(board, userData: nil, error: &legacyError)
        precondition(legacyError == nil && opened.last == folder)
        count += 1
        let unchangedData = try Data(contentsOf: file)
        let folderContents = try manager.contentsOfDirectory(atPath: folder.path)
        precondition(unchangedData == Data("unchanged media fixture".utf8))
        precondition(folderContents.isEmpty)
        print("PASS: \(count) native service cases; selector, modern/legacy pasteboards, validation, no file changes")
    }
}

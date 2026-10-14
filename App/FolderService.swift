import AppKit

/// A native macOS service. It selects a folder; it never starts media processing.
@MainActor
final class PhotomuriFolderService: NSObject {
    private let openFolder: (URL) -> Void

    init(openFolder: ((URL) -> Void)? = nil) {
        self.openFolder = openFolder ?? Self.openInPhotomuri
        super.init()
    }

    @objc(organizeFolder:userData:error:)
    func organizeFolder(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) {
        let modernURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        let urls: [URL]
        if !modernURLs.isEmpty {
            urls = modernURLs
        } else {
            // Older Finder/service pasteboards may send a list of file paths.
            let paths = pasteboard.propertyList(
                forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
            ) as? [String] ?? []
            urls = paths.map { URL(fileURLWithPath: $0) }
        }

        guard urls.count == 1, let url = urls.first, url.isFileURL else {
            error?.pointee = "Select one working folder in Finder." as NSString
            return
        }
        let scopedAccess = url.startAccessingSecurityScopedResource()
        defer { if scopedAccess { url.stopAccessingSecurityScopedResource() } }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
              values.isDirectory == true, values.isPackage != true else {
            error?.pointee = "Choose a folder containing photos or videos. Files and apps are not supported." as NSString
            return
        }
        openFolder(url)
    }

    private static func openInPhotomuri(_ url: URL) {
        // Use our own bundle URL, never a hard-coded Debug/Applications path.
        // The existing onOpenURL route handles bookmarks, busy state and windows.
        let scopedAccess = url.startAccessingSecurityScopedResource()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            DispatchQueue.main.async {
                if scopedAccess { url.stopAccessingSecurityScopedResource() }
                if let error {
                    let alert = NSAlert()
                    alert.messageText = "Unable to Add Folder"
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }
}

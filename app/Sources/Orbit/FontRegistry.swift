import CoreText
import Foundation

/// Registers fonts shipped in the app bundle's `Fonts` folder for this process.
enum FontRegistry {
    static func registerBundledFonts() {
        if let folder = Bundle.main.resourceURL?.appendingPathComponent("Fonts") { register(folder: folder) }
    }

    static func register(folder: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for url in files where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

import CoreGraphics
import Foundation
import ImageIO

struct Preview: Sendable {
    let image: CGImage
    /// Size of the original, which the boxes are stored in, not of the downsampled preview.
    let pixelSize: CGSize
}

/// Downsampled pages for the canvas. A 600 dpi scan takes ~0.3 s to decode,
/// so neighbours are decoded ahead and paging through a folder feels instant.
@MainActor
final class PreviewCache {
    // Long side in pixels; enough for a full-height canvas on a Retina display.
    nonisolated static let maxPixelSize = 3000

    private var tasks: [URL: Task<Preview?, Never>] = [:]

    func preview(for url: URL) async -> Preview? {
        await task(for: url).value
    }

    /// Starts decoding `urls` and drops everything else, so memory stays flat however big the folder is.
    func keep(only urls: [URL]) {
        for url in urls { _ = task(for: url) }
        for url in tasks.keys where !urls.contains(url) {
            tasks.removeValue(forKey: url)?.cancel()
        }
    }

    func removeAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    private func task(for url: URL) -> Task<Preview?, Never> {
        if let task = tasks[url] { return task }
        let task = Task.detached(priority: .userInitiated) { Self.decode(url) }
        tasks[url] = task
        return task
    }

    nonisolated static func decode(_ url: URL) -> Preview? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { return nil }
        return Preview(image: image, pixelSize: CGSize(width: width, height: height))
    }

    nonisolated static func decodeFull(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

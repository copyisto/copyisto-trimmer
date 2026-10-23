import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Sendable {
    case png, jpg

    var label: String { rawValue.uppercased() }
    var type: UTType { self == .png ? .png : .jpeg }
}

struct ExportJob: Sendable {
    let source: URL
    let image: String
    let boxes: [Box]
    var rotation = 0.0
}

struct ExportSummary: Equatable, Sendable {
    var crops = 0
    var images = 0
    var folders: [URL] = []
    /// The notebooks exported, by title; none when every notebook's crops were up to date.
    var notebooks: [String] = []
}

enum ExportError: LocalizedError {
    case unreadable(String)
    case unwritable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "Nie udało się odczytać zdjęcia „\(name)”."
        case .unwritable(let name): "Nie udało się zapisać wycinka „\(name)”."
        }
    }
}

enum Exporter {
    // ponytail: a 600 dpi page decodes to ~140 MB, so cap parallel pages; raise if exports feel slow
    static let maxConcurrentPages = 4

    /// Writes every box as its own file into `<folder>/.trims/crops/`, then removes crops whose box is gone.
    /// Removal only happens after every page succeeded, so a failed export never deletes anything.
    @concurrent
    static func run(
        folder: URL, images: [String], trims: [String: ImageTrims], format: ExportFormat,
        progress: @MainActor @Sendable (Int, Int) -> Void
    ) async throws -> ExportSummary {
        let output = TrimsLocation.crops(in: folder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let jobs = images.compactMap { image -> ExportJob? in
            guard let page = trims[image], !page.boxes.isEmpty else { return nil }
            return ExportJob(
                source: folder.appending(path: image), image: image, boxes: page.boxes, rotation: page.rotation ?? 0)
        }

        var written = Set<String>()
        try await withThrowingTaskGroup(of: [String].self) { group in
            var pending = jobs.makeIterator()
            for _ in 0..<maxConcurrentPages {
                guard let job = pending.next() else { break }
                group.addTask { try write(job, to: output, format: format) }
            }
            var done = 0
            await progress(done, jobs.count)
            while let names = try await group.next() {
                written.formUnion(names)
                done += 1
                await progress(done, jobs.count)
                if let job = pending.next() {
                    group.addTask { try write(job, to: output, format: format) }
                }
            }
        }

        let existing = try FileManager.default.contentsOfDirectory(atPath: output.path)
        for stale in staleCrops(in: existing, images: images, keep: written) {
            try FileManager.default.removeItem(at: output.appending(path: stale))
        }
        return ExportSummary(crops: written.count, images: jobs.count, folders: [output])
    }

    /// Decodes one page once and writes all of its boxes; returns the file names written.
    static func write(_ job: ExportJob, to output: URL, format: ExportFormat) throws -> [String] {
        guard let source = CGImageSourceCreateWithURL(job.source as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw ExportError.unreadable(job.image) }

        // Keep the scan's dpi, so a crop still says it is 600 dpi.
        let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var properties: [CFString: Any] = [:]
        for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            properties[key] = sourceProperties[key]
        }
        if format == .jpg {
            // Same quality as the ingestor's photo editor.
            properties[kCGImageDestinationLossyCompressionQuality] = 0.95
        }

        let size = CGSize(width: image.width, height: image.height)
        var names: [String] = []
        for (index, box) in job.boxes.enumerated() {
            // A box can fall outside a page that was re-scanned at a smaller size; skip it rather than crop garbage.
            let rect = clamped(box.rect, to: size)
            guard isUsable(rect) else { continue }
            // A level page is cropped as is, so its crops keep the scan's exact pixels.
            guard let crop = job.rotation == 0
                ? image.cropping(to: rect) : renderRotated(image, degrees: job.rotation, crop: rect)
            else { throw ExportError.unwritable(cropFileName(image: job.image, number: index + 1, format: format)) }
            let name = cropFileName(image: job.image, number: index + 1, format: format)
            let destination = output.appending(path: name)
            // Written beside the target and renamed over it, so an interrupted export never leaves a half-written crop.
            let temporary = output.appending(path: ".\(name).tmp")
            guard let writer = CGImageDestinationCreateWithURL(
                temporary as CFURL, format.type.identifier as CFString, 1, nil)
            else { throw ExportError.unwritable(name) }
            CGImageDestinationAddImage(writer, crop, properties as CFDictionary)
            guard CGImageDestinationFinalize(writer), rename(temporary.path, destination.path) == 0 else {
                try? FileManager.default.removeItem(at: temporary)
                throw ExportError.unwritable(name)
            }
            names.append(name)
        }
        return names
    }
}

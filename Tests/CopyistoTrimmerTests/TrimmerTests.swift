import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import CopyistoTrimmer

@Test func mappingRoundTripsBetweenViewAndPixels() {
    let mapping = Mapping(imageSize: CGSize(width: 4960, height: 7016), canvas: CGSize(width: 900, height: 1000), padding: 24)
    // Fitted by height: (1000 - 48) / 7016.
    #expect(abs(mapping.scale - 952.0 / 7016) < 1e-9)
    #expect(abs(mapping.origin.y - 24) < 1e-9)
    let pixel = CGPoint(x: 1234, y: 5678)
    let back = mapping.toImage(mapping.toView(pixel))
    #expect(abs(back.x - pixel.x) < 1e-6 && abs(back.y - pixel.y) < 1e-6)
}

@Test func resizingMovesOnlyTheHandledEdges() {
    let box = CGRect(x: 100, y: 100, width: 200, height: 100)
    #expect(resized(box, handle: .bottomRight, to: CGPoint(x: 400, y: 250)) == CGRect(x: 100, y: 100, width: 300, height: 150))
    #expect(resized(box, handle: .top, to: CGPoint(x: 999, y: 50)) == CGRect(x: 100, y: 50, width: 200, height: 150))
    #expect(resized(box, handle: .left, to: CGPoint(x: 150, y: 999)) == CGRect(x: 150, y: 100, width: 150, height: 100))
}

@Test func resizingPastTheOppositeEdgeFlipsTheBox() {
    let box = CGRect(x: 100, y: 100, width: 200, height: 100)
    #expect(resized(box, handle: .left, to: CGPoint(x: 350, y: 0)) == CGRect(x: 300, y: 100, width: 50, height: 100))
    #expect(resized(box, handle: .topLeft, to: CGPoint(x: 400, y: 300)) == CGRect(x: 300, y: 200, width: 100, height: 100))
}

@Test func boxesStayInsideTheImage() {
    let size = CGSize(width: 1000, height: 800)
    #expect(clamped(CGRect(x: -50, y: 700.4, width: 300, height: 300), to: size) == CGRect(x: 0, y: 700, width: 250, height: 100))
    #expect(clamped(CGRect(x: 2000, y: 0, width: 10, height: 10), to: size) == .zero)
    let box = CGRect(x: 900, y: 10, width: 80, height: 50)
    #expect(moved(box, by: CGSize(width: 500, height: -500), within: size) == CGRect(x: 920, y: 0, width: 80, height: 50))
}

@Test func strayClicksAreNotBoxes() {
    #expect(!isUsable(.zero))
    #expect(!isUsable(CGRect(x: 0, y: 0, width: 300, height: 15)))
    #expect(isUsable(CGRect(x: 0, y: 0, width: 16, height: 16)))
}

@Test func newBoxesGetUniqueIds() {
    var trims = ImageTrims(size: CGSize(width: 100, height: 100))
    trims.add(CGRect(x: 0, y: 0, width: 20, height: 20))
    trims.add(CGRect(x: 0, y: 0, width: 30, height: 30))
    trims.boxes.removeAll { $0.id == 1 }
    #expect(trims.add(CGRect(x: 0, y: 0, width: 40, height: 40)) == 3)
    #expect(trims.boxes.map(\.id) == [2, 3])
}

@Test func cropNamesUseTheBoxNumber() {
    #expect(cropFileName(image: "4H8-E_001.png", number: 7, format: .png) == "4H8-E_001_007.png")
    #expect(cropFileName(image: "scan.v2.jpeg", number: 1234, format: .jpg) == "scan.v2_1234.jpg")
}

@Test func onlyOwnOutdatedCropsAreCleanedUp() {
    let files = [
        "A_001.png",  // kept: still a box
        "A_002.png",  // stale: box deleted
        "A_001.jpg",  // stale: other format
        "A_002.json",  // labelme annotation, not ours
        "A_001_002.png",  // crop of page "A_001", which is not in this folder
        "B_01.png",  // too few digits to be ours
        "notes.txt",
    ]
    let stale = staleCrops(in: files, images: ["A.png"], keep: ["A_001.png"])
    #expect(Set(stale) == ["A_002.png", "A_001.jpg"])
}

@Test func polishPlurals() {
    #expect(plural(1, "wycinek", "wycinki", "wycinków") == "1 wycinek")
    #expect(plural(3, "wycinek", "wycinki", "wycinków") == "3 wycinki")
    #expect(plural(12, "wycinek", "wycinki", "wycinków") == "12 wycinków")
    #expect(plural(22, "wycinek", "wycinki", "wycinków") == "22 wycinki")
    #expect(plural(0, "wycinek", "wycinki", "wycinków") == "0 wycinków")
}

@Test func trimsFileRoundTrips() throws {
    let folder = try temporaryFolder()
    var file = TrimsFile()
    var page = ImageTrims(size: CGSize(width: 4960, height: 7016))
    page.add(CGRect(x: 120, y: 840, width: 4700, height: 1300))
    page.rotation = -0.46
    file.images["4H8-E_001.png"] = page
    file.images["empty.png"] = ImageTrims(size: CGSize(width: 10, height: 10))
    try file.save(to: folder)
    #expect(try TrimsFile.load(from: folder) == file)
    #expect(try TrimsFile.load(from: try temporaryFolder()) == TrimsFile())
}

@Test func newerTrimsFilesAreRefused() throws {
    let folder = try temporaryFolder()
    try Data(#"{"version": \#(TrimsFile.currentVersion + 1), "images": {}}"#.utf8)
        .write(to: folder.appending(path: TrimsFile.fileName))
    #expect(throws: TrimsError.self) { try TrimsFile.load(from: folder) }
}

@Test func version1FilesStillLoad() throws {
    let folder = try temporaryFolder()
    let json = #"{"version": 1, "images": {"a.png": {"width": 10, "height": 20, "nextId": 3, "boxes": []}}}"#
    try Data(json.utf8).write(to: folder.appending(path: TrimsFile.fileName))
    let page = try #require(try TrimsFile.load(from: folder).images["a.png"])
    #expect(page.size == CGSize(width: 10, height: 20) && page.rotation == nil)
}

@Test func positiveRotationTurnsClockwise() {
    let size = CGSize(width: 200, height: 200)
    // The middle of the right edge goes to the middle of the bottom edge.
    let point = rotated(CGPoint(x: 200, y: 100), by: 90, in: size)
    #expect(abs(point.x - 100) < 1e-9 && abs(point.y - 200) < 1e-9)
}

@Test func exportRendersRotatedPagesAsTheCanvasShowsThem() async throws {
    let folder = try temporaryFolder()
    // Top left quarter red, the rest blue; turned 90° clockwise, the red quarter is top right.
    try writePNG(width: 100, height: 100, to: folder.appending(path: "page.png")) { x, y in
        x < 50 && y < 50 ? (255, 0, 0) : (0, 0, 255)
    }
    var page = ImageTrims(size: CGSize(width: 100, height: 100))
    page.add(CGRect(x: 55, y: 5, width: 40, height: 40))
    page.add(CGRect(x: 5, y: 5, width: 40, height: 40))
    page.rotation = 90
    _ = try await Exporter.run(folder: folder, images: ["page.png"], trims: ["page.png": page], format: .png) { _, _ in }

    let output = folder.appending(path: Exporter.folderName)
    let red = try #require(loadImage(output.appending(path: "page_001.png")))
    let blue = try #require(loadImage(output.appending(path: "page_002.png")))
    #expect(red.width == 40 && red.height == 40)
    #expect(try rgb(of: red, x: 0, y: 0) == [255, 0, 0] && rgb(of: red, x: 39, y: 39) == [255, 0, 0])
    #expect(try rgb(of: blue, x: 0, y: 0) == [0, 0, 255] && rgb(of: blue, x: 39, y: 39) == [0, 0, 255])
}

@Test func straightenUndoesTheTiltOfAPage() throws {
    // Staves of five lines, like a manuscript notebook, then tilted the way the export turns pages.
    let level = try makeImage(width: 800, height: 1100) { _, y in
        (y % 150) < 50 && y % 10 == 0 ? (90, 140, 220) : (250, 248, 240)
    }
    #expect(abs(Straighten.angle(of: level)) <= 0.02)
    for tilt in [0.5, -1.3] {
        let tilted = try #require(renderRotated(level, degrees: tilt, crop: CGRect(x: 0, y: 0, width: 800, height: 1100)))
        #expect(abs(Straighten.angle(of: tilted) + tilt) <= 0.05)
    }
}

@Test func exportCropsExactPixelsAndRemovesStaleCrops() async throws {
    let folder = try temporaryFolder()
    // 100x80 image: top left red, top right blue, bottom half green, so a flipped or shifted crop shows.
    try writePNG(width: 100, height: 80, to: folder.appending(path: "page.png")) { x, y in
        y >= 40 ? (0, 255, 0) : x < 50 ? (255, 0, 0) : (0, 0, 255)
    }
    let output = folder.appending(path: Exporter.folderName)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for leftover in ["page_009.png", "page_009.json"] {
        try Data().write(to: output.appending(path: leftover))
    }

    var page = ImageTrims(size: CGSize(width: 100, height: 80))
    // Boxes 1-7 drawn and deleted: the one left is still crop number 1, as on screen.
    for _ in 1...7 { page.add(CGRect(x: 0, y: 0, width: 20, height: 20)) }
    page.add(CGRect(x: 60, y: 15, width: 30, height: 20))
    page.boxes.removeAll { $0.id < 8 }
    #expect(page.boxes.map(\.id) == [8])
    let summary = try await Exporter.run(
        folder: folder, images: ["page.png"], trims: ["page.png": page], format: .png
    ) { _, _ in }

    #expect(summary.crops == 1 && summary.images == 1)
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: output.path)) == ["page_001.png", "page_009.json"])
    let crop = try #require(
        CGImageSourceCreateWithURL(output.appending(path: "page_001.png") as CFURL, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
    #expect(crop.width == 30 && crop.height == 20)
    #expect(try rgb(of: crop, x: 0, y: 0) == [0, 0, 255])
    #expect(try rgb(of: crop, x: 29, y: 19) == [0, 0, 255])
}

// MARK: Helpers

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "copyisto-trimmer-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writePNG(width: Int, height: Int, to url: URL, color: (Int, Int) -> (UInt8, UInt8, UInt8)) throws {
    let image = try makeImage(width: width, height: height, color: color)
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

private func loadImage(_ url: URL) -> CGImage? {
    CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
}

private func makeImage(width: Int, height: Int, color: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CGImage {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b) = color(x, y)
            let i = (y * width + x) * 4
            (pixels[i], pixels[i + 1], pixels[i + 2]) = (r, g, b)
        }
    }
    let context = try #require(
        CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    return try #require(context.makeImage())
}

private func rgb(of image: CGImage, x: Int, y: Int) throws -> [UInt8] {
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = try #require(
        CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return Array(pixel[0..<3])
}

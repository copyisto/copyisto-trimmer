import CoreGraphics
import Foundation

/// Boxes shorter than this on either side are dropped, so a stray click never becomes a crop.
let minimumBoxSide: CGFloat = 16

/// Maps between image pixels and canvas points for an image fitted into the canvas.
struct Mapping: Equatable {
    var scale: CGFloat
    var origin: CGPoint

    init(scale: CGFloat, origin: CGPoint) {
        self.scale = scale
        self.origin = origin
    }

    /// Fits the whole image inside the canvas, centred.
    init(imageSize: CGSize, canvas: CGSize, padding: CGFloat) {
        let available = CGSize(
            width: max(canvas.width - padding * 2, 1),
            height: max(canvas.height - padding * 2, 1))
        scale = min(available.width / imageSize.width, available.height / imageSize.height)
        origin = CGPoint(
            x: (canvas.width - imageSize.width * scale) / 2,
            y: (canvas.height - imageSize.height * scale) / 2)
    }

    func toView(_ point: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
    }

    func toView(_ rect: CGRect) -> CGRect {
        CGRect(origin: toView(rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale))
    }

    func toImage(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
    }
}

enum Handle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    func point(on rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        }
    }
}

/// Moves the edges the handle controls to `point`.
/// Dragging past the opposite edge flips the box instead of giving it a negative size.
func resized(_ rect: CGRect, handle: Handle, to point: CGPoint) -> CGRect {
    var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
    switch handle {
    case .topLeft, .left, .bottomLeft: minX = point.x
    case .topRight, .right, .bottomRight: maxX = point.x
    case .top, .bottom: break
    }
    switch handle {
    case .topLeft, .top, .topRight: minY = point.y
    case .bottomLeft, .bottom, .bottomRight: maxY = point.y
    case .left, .right: break
    }
    return spanning(CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY))
}

/// The rectangle spanned by two corners, in any order.
func spanning(_ a: CGPoint, _ b: CGPoint) -> CGRect {
    CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
}

/// Trims the rectangle to the image and snaps it to whole pixels.
func clamped(_ rect: CGRect, to size: CGSize) -> CGRect {
    let r = rect.intersection(CGRect(origin: .zero, size: size))
    guard !r.isNull else { return .zero }
    let minX = r.minX.rounded(), minY = r.minY.rounded()
    return CGRect(x: minX, y: minY, width: r.maxX.rounded() - minX, height: r.maxY.rounded() - minY)
}

/// Shifts the rectangle by `delta` but keeps all of it inside the image.
func moved(_ rect: CGRect, by delta: CGSize, within size: CGSize) -> CGRect {
    let x = min(max(rect.minX + delta.width, 0), size.width - rect.width)
    let y = min(max(rect.minY + delta.height, 0), size.height - rect.height)
    return CGRect(x: x.rounded(), y: y.rounded(), width: rect.width, height: rect.height)
}

func isUsable(_ rect: CGRect) -> Bool {
    rect.width >= minimumBoxSide && rect.height >= minimumBoxSide
}

/// The 7th box on `4H8-E_001.png` becomes `4H8-E_001_007.png`.
func cropFileName(image: String, number: Int, format: ExportFormat) -> String {
    "\(stem(of: image))_\(String(format: "%03d", number)).\(format.rawValue)"
}

func stem(of fileName: String) -> String {
    (fileName as NSString).deletingPathExtension
}

/// Crops this app wrote earlier for one of `images` that are not in `keep`.
/// Anything else in the folder, such as labelme `.json` files, is never touched.
func staleCrops(in files: [String], images: [String], keep: Set<String>) -> [String] {
    let stems = Set(images.map(stem(of:)))
    return files.filter { file in
        guard !keep.contains(file) else { return false }
        let ext = (file as NSString).pathExtension
        guard ExportFormat(rawValue: ext) != nil else { return false }
        let name = stem(of: file)
        guard let underscore = name.lastIndex(of: "_") else { return false }
        let id = name[name.index(after: underscore)...]
        return id.count >= 3 && id.allSatisfy(\.isASCIIDigit) && stems.contains(String(name[..<underscore]))
    }
}

/// Polish plural: 1 wycinek, 2 wycinki, 5 wycinków, 22 wycinki, 12 wycinków.
func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    if n == 1 { return "\(n) \(one)" }
    let (tens, units) = (n % 100, n % 10)
    let word = (2...4).contains(units) && !(12...14).contains(tens) ? few : many
    return "\(n) \(word)"
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

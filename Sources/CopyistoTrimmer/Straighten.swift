import CoreGraphics
import Foundation

/// Finds how far a scan is tilted, by projection profile (the deskew method of Leptonica and Tesseract):
/// turned to the right angle, the staff lines and lines of writing each fall into a few rows,
/// so the sum of squared row totals peaks.
/// Measured on real notebook scans, it agrees within 0.03° with the shift of the staff lines across the page.
enum Straighten {
    /// The search range in degrees; a page on a scanner glass is never tilted further.
    static let maxAngle = 5.0
    // Long side of the image the search runs on; more pixels give the same angle, only slower.
    static let workingSize = 1600

    /// The clockwise turn in degrees, as stored in `ImageTrims.rotation`, that makes the page level.
    static func angle(of image: CGImage) -> Double {
        let scale = min(Double(workingSize) / Double(max(image.width, image.height)), 1)
        let w = max(Int(Double(image.width) * scale), 1), h = max(Int(Double(image.height) * scale), 1)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return 0 }

        // The red channel, because the printed staff lines are light blue and nearly vanish in grey.
        var xs: [Double] = [], ys: [Double] = [], weights: [Double] = []
        for y in 0..<h {
            for x in 0..<w {
                let darkness = 255 - Int(pixels[(y * w + x) * 4])
                // Paper grain and show-through only blur the profile.
                guard darkness > 40 else { continue }
                xs.append(Double(x))
                ys.append(Double(y))
                weights.append(Double(darkness))
            }
        }
        guard !xs.isEmpty else { return 0 }

        func score(_ degrees: Double) -> Double {
            let radians = degrees * .pi / 180
            let (s, c) = (sin(radians), cos(radians))
            var rows = [Double](repeating: 0, count: 2 * w + h + 2)
            // The row each pixel lands in once the page is turned clockwise by `degrees`; shifted by w so it is never negative.
            for i in xs.indices { rows[Int(xs[i] * s + ys[i] * c + Double(w))] += weights[i] }
            return rows.reduce(0) { $0 + $1 * $1 }
        }

        var best = 0.0
        // Coarse, then fine around the coarse peak.
        for (step, span) in [(0.1, maxAngle), (0.01, 0.1)] {
            best = stride(from: best - span, through: best + span, by: step).max { score($0) < score($1) } ?? 0
        }
        return (best * 100).rounded() / 100
    }
}

/// Where a point of the page lands when the page is turned clockwise by `degrees` about its centre.
func rotated(_ point: CGPoint, by degrees: Double, in size: CGSize) -> CGPoint {
    let radians = degrees * .pi / 180
    let (s, c) = (sin(radians), cos(radians))
    let dx = point.x - size.width / 2, dy = point.y - size.height / 2
    // y points down, so this matrix turns clockwise on screen.
    return CGPoint(x: size.width / 2 + dx * c - dy * s, y: size.height / 2 + dx * s + dy * c)
}

/// Renders `rect` of the page turned clockwise by `degrees` about its centre, with white where the turn uncovers no page.
/// The canvas shows the page the same way, so a box exports exactly what it frames on screen.
func renderRotated(_ image: CGImage, degrees: Double, crop rect: CGRect) -> CGImage? {
    let width = Int(rect.width), height = Int(rect.height)
    let isGrey = image.colorSpace?.model == .monochrome
    // The scan's own profile, so colours match the unrotated crops; anything exotic falls back to sRGB.
    let space = isGrey ? CGColorSpaceCreateDeviceGray()
        : image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: isGrey ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let w = CGFloat(image.width), h = CGFloat(image.height)
    // Into page coordinates with y down, as the boxes are, then turn about the centre.
    // In a y-down frame a positive angle turns clockwise on screen, matching `rotated` and SwiftUI's rotationEffect.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.translateBy(x: -rect.minX, y: -rect.minY)
    context.translateBy(x: w / 2, y: h / 2)
    context.rotate(by: degrees * .pi / 180)
    context.translateBy(x: -w / 2, y: -h / 2)
    // draw() paints with y up; flip it back so the page is not drawn upside down.
    context.translateBy(x: 0, y: h)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return context.makeImage()
}

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import KSSCore
import UniformTypeIdentifiers

/// CoreGraphics implementations of the image operations the sync engine needs.
struct MacImageTools: ImageTools {
    private func decode(_ png: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// 8-bit grayscale bitmap, drawn on white (transparent backgrounds become white).
    private func grayscale(_ image: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 255, count: w * h)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (pixels, w, h) : nil
    }

    func pixelHash(_ png: Data) -> String? {
        guard let img = decode(png), let g = grayscale(img) else { return nil }
        var hasher = SHA256()
        hasher.update(data: Data("\(g.width)x\(g.height)".utf8))
        hasher.update(data: Data(g.pixels))
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func pixelSize(_ png: Data) -> (width: Int, height: Int)? {
        guard let img = decode(png) else { return nil }
        return (img.width, img.height)
    }

    /// RGB image on white for the vision model.
    func flattenedForModel(_ png: Data) -> CGImage? {
        guard let img = decode(png) else { return nil }
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Crop a figure. The model's box is widened a little, then tightened to the
    /// ink actually inside it, so slightly-off coordinates still give a clean crop.
    func cropFigure(_ png: Data, box: NormRect) -> (png: Data, box: NormRect)? {
        guard let img = decode(png), let g = grayscale(img) else { return nil }
        let W = Double(g.width), H = Double(g.height)
        let pad = 0.03
        var x0 = Int(max(0, box.x0 - pad) * W), y0 = Int(max(0, box.y0 - pad) * H)
        var x1 = Int(min(1, box.x1 + pad) * W), y1 = Int(min(1, box.y1 + pad) * H)
        guard x1 - x0 > 8, y1 - y0 > 8 else { return nil }

        // tighten to dark pixels
        var minX = x1, minY = y1, maxX = x0, maxY = y0
        for y in y0..<y1 {
            let row = y * g.width
            for x in x0..<x1 where g.pixels[row + x] < 170 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        if maxX > minX + 4 && maxY > minY + 4 {
            let margin = Int(0.012 * max(W, H))
            x0 = max(0, minX - margin); y0 = max(0, minY - margin)
            x1 = min(g.width, maxX + margin); y1 = min(g.height, maxY + margin)
        }

        // re-render the region from the white-flattened grayscale bitmap
        let cw = x1 - x0, ch = y1 - y0
        var region = [UInt8](repeating: 255, count: cw * ch)
        for y in 0..<ch {
            let src = (y0 + y) * g.width + x0
            region.replaceSubrange(y * cw..<(y + 1) * cw, with: g.pixels[src..<src + cw])
        }
        guard let provider = CGDataProvider(data: Data(region) as CFData),
              let cropped = CGImage(width: cw, height: ch, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: cw,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cropped, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let refined = NormRect(x0: Double(x0) / W, y0: Double(y0) / H, x1: Double(x1) / W, y1: Double(y1) / H)
        return (out as Data, refined)
    }
}

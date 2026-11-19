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

    /// Crop a figure. The model's box is only a hint: the crop snaps to the connected
    /// ink of the drawing (see FigureLocator), so slightly-off coordinates still give
    /// the whole drawing and no neighbouring text.
    func cropFigure(_ png: Data, box: NormRect) -> (png: Data, box: NormRect)? {
        guard let img = decode(png), let g = grayscale(img) else { return nil }
        let W = Double(g.width), H = Double(g.height)
        var x0: Int, y0: Int, x1: Int, y1: Int
        if let r = FigureLocator.locate(gray: g.pixels, width: g.width, height: g.height, hint: box) {
            (x0, y0, x1, y1) = (r.x0, r.y0, r.x1, r.y1)
        } else {
            // no ink found near the hint: take the hint as it is
            x0 = Int(box.x0 * W); y0 = Int(box.y0 * H); x1 = Int(box.x1 * W); y1 = Int(box.y1 * H)
            guard x1 - x0 > 8, y1 - y0 > 8 else { return nil }
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

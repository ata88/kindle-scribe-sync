import AppKit
func make(_ path: String, _ label: String) {
  let w = 500, h = 360
  let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
  c.setFillColor(gray: 1, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
  c.setStrokeColor(gray: 0, alpha: 1); c.setLineWidth(10); c.stroke(CGRect(x: 40, y: 40, width: 420, height: 280))
  let a = NSAttributedString(string: label, attributes: [.font: NSFont.boldSystemFont(ofSize: 90)])
  NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false); a.draw(at: NSPoint(x: 120, y: 120))
  let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
make(CommandLine.arguments[1], "ONE"); make(CommandLine.arguments[2], "TWO")

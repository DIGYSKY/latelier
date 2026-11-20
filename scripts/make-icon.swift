// Dessine l'icône de L’Atelier (1024 px) : clé blanche sur fond bleu de la maquette.
//   swift scripts/make-icon.swift Support/AppIcon.png
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
// Gabarit macOS : carré arrondi de 824 px centré.
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor(red: 0.04, green: 0.42, blue: 0.86, alpha: 1).setFill()
shape.fill()
NSGraphicsContext.current?.restoreGraphicsState()
let gradient = NSGradient(colors: [
    NSColor(red: 0.55, green: 0.77, blue: 1.0, alpha: 1),
    NSColor(red: 0.04, green: 0.42, blue: 0.86, alpha: 1),
    NSColor(red: 0.43, green: 0.29, blue: 0.85, alpha: 1),
])!
gradient.draw(in: shape, angle: -60)
// Reflet du haut, façon verre.
let shine = NSBezierPath(roundedRect: rect.insetBy(dx: 10, dy: 10), xRadius: 175, yRadius: 175)
NSGradient(colors: [NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0)])!.draw(in: shine, angle: -90)
let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "wrench.adjustable", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let s = symbol.size
    symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
}
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

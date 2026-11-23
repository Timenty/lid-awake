import AppKit

// Кружка 18×18pt. coffee=nil — пустая (template), иначе — налито + пар.
func mugImage(fg: NSColor, coffee: NSColor?) -> NSImage {
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        let l: CGFloat = 3, r: CGFloat = 12.5, b: CGFloat = 1.5, t: CGFloat = 11, rad: CGFloat = 2.5
        func body(top: CGFloat) -> NSBezierPath {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: l, y: top))
            p.line(to: NSPoint(x: l, y: b + rad))
            p.appendArc(withCenter: NSPoint(x: l + rad, y: b + rad), radius: rad, startAngle: 180, endAngle: 270)
            p.line(to: NSPoint(x: r - rad, y: b))
            p.appendArc(withCenter: NSPoint(x: r - rad, y: b + rad), radius: rad, startAngle: 270, endAngle: 360)
            p.line(to: NSPoint(x: r, y: top))
            return p
        }
        if let coffee {
            let c = body(top: 8.6); c.close(); coffee.setFill(); c.fill()
            let steam = NSBezierPath()
            for x: CGFloat in [5.6, 9.6] {
                steam.move(to: NSPoint(x: x, y: 12.4))
                steam.curve(to: NSPoint(x: x, y: 16.6), controlPoint1: NSPoint(x: x - 1.4, y: 13.8),
                            controlPoint2: NSPoint(x: x + 1.4, y: 15.2))
            }
            steam.lineWidth = 1.2; steam.lineCapStyle = .round
            fg.withAlphaComponent(0.55).setStroke(); steam.stroke()
        }
        let cup = body(top: t)
        cup.appendArc(withCenter: NSPoint(x: r, y: 6.5), radius: 2.6, startAngle: 270, endAngle: 90, clockwise: false)
        cup.lineWidth = 1.4; cup.lineJoinStyle = .round; cup.lineCapStyle = .round
        fg.setStroke(); cup.stroke()
        return true
    }
    img.isTemplate = coffee == nil
    return img
}

import AppKit

struct Stroke {
    let points: [CGPoint]
    let color: NSColor
    let lineWidth: CGFloat
}

final class AnnotationCanvasView: NSView {
    private(set) var strokes: [Stroke] = []
    private var currentPoints: [CGPoint] = []

    var baseImage: NSImage {
        didSet {
            needsDisplay = true
        }
    }

    var strokeColor: NSColor = .systemBlue
    var strokeWidth: CGFloat = 6

    init(image: NSImage) {
        self.baseImage = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.9).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.black.withAlphaComponent(0.92).setFill()
        dirtyRect.fill()

        let imageRect = fittedImageRect(in: bounds.insetBy(dx: 20, dy: 20))
        baseImage.draw(in: imageRect)

        for stroke in strokes {
            draw(stroke: stroke, in: imageRect)
        }

        if !currentPoints.isEmpty {
            let previewStroke = Stroke(points: currentPoints, color: strokeColor, lineWidth: strokeWidth)
            draw(stroke: previewStroke, in: imageRect)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let point = normalizedPoint(for: convert(event.locationInWindow, from: nil)) else {
            currentPoints = []
            return
        }

        window?.makeFirstResponder(self)
        currentPoints = [point]
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !currentPoints.isEmpty,
              let point = normalizedPoint(for: convert(event.locationInWindow, from: nil)) else {
            return
        }

        currentPoints.append(point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !currentPoints.isEmpty else { return }

        strokes.append(Stroke(points: currentPoints, color: strokeColor, lineWidth: strokeWidth))
        currentPoints = []
        needsDisplay = true
    }

    func undoLastStroke() {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
        needsDisplay = true
    }

    func clearStrokes() {
        strokes.removeAll()
        currentPoints = []
        needsDisplay = true
    }

    func renderedImage() -> NSImage {
        let result = NSImage(size: baseImage.size)
        result.lockFocus()
        defer { result.unlockFocus() }

        let targetRect = CGRect(origin: .zero, size: baseImage.size)
        baseImage.draw(in: targetRect)

        for stroke in strokes {
            let path = NSBezierPath()
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            path.lineWidth = stroke.lineWidth
            stroke.color.setStroke()

            for (index, point) in stroke.points.enumerated() {
                let scaled = CGPoint(x: point.x * baseImage.size.width, y: point.y * baseImage.size.height)
                if index == 0 {
                    path.move(to: scaled)
                } else {
                    path.line(to: scaled)
                }
            }
            path.stroke()
        }

        return result
    }

    private func fittedImageRect(in rect: CGRect) -> CGRect {
        guard baseImage.size.width > 0, baseImage.size.height > 0 else { return rect }

        let widthRatio = rect.width / baseImage.size.width
        let heightRatio = rect.height / baseImage.size.height
        let scale = min(widthRatio, heightRatio)

        let drawSize = CGSize(width: baseImage.size.width * scale, height: baseImage.size.height * scale)
        let origin = CGPoint(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2
        )

        return CGRect(origin: origin, size: drawSize)
    }

    private func normalizedPoint(for point: CGPoint) -> CGPoint? {
        let imageRect = fittedImageRect(in: bounds.insetBy(dx: 20, dy: 20))
        guard imageRect.contains(point) else { return nil }

        let x = (point.x - imageRect.minX) / imageRect.width
        let y = (point.y - imageRect.minY) / imageRect.height
        return CGPoint(x: x, y: y)
    }

    private func draw(stroke: Stroke, in imageRect: CGRect) {
        guard stroke.points.count >= 1 else { return }

        let path = NSBezierPath()
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.lineWidth = stroke.lineWidth
        stroke.color.setStroke()

        for (index, point) in stroke.points.enumerated() {
            let scaled = CGPoint(
                x: imageRect.minX + point.x * imageRect.width,
                y: imageRect.minY + point.y * imageRect.height
            )

            if index == 0 {
                path.move(to: scaled)
            } else {
                path.line(to: scaled)
            }
        }

        path.stroke()
    }
}

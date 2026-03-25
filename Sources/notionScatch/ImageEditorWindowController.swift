import AppKit

final class ImageEditorWindowController: NSWindowController {
    private let canvasView: AnnotationCanvasView
    private let onCommit: (NSImage) -> Void

    init(image: NSImage, onCommit: @escaping (NSImage) -> Void) {
        self.canvasView = AnnotationCanvasView(image: image)
        self.onCommit = onCommit

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Notion Scatch"
        window.center()
        super.init(window: window)

        configureUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureUI() {
        guard let window else { return }

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let titleLabel = NSTextField(labelWithString: "선택한 Notion 이미지를 편집한 뒤 확인을 누르면 원래 자리로 교체를 시도합니다.")
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor

        let colorWell = NSColorWell()
        colorWell.color = .systemBlue
        colorWell.target = self
        colorWell.action = #selector(changeColor(_:))

        let widthLabel = NSTextField(labelWithString: "선 굵기")
        let widthSlider = NSSlider(value: 6, minValue: 1, maxValue: 24, target: self, action: #selector(changeWidth(_:)))

        let undoButton = NSButton(title: "되돌리기", target: self, action: #selector(undoStroke))
        let clearButton = NSButton(title: "모두 지우기", target: self, action: #selector(clearAll))
        let cancelButton = NSButton(title: "취소", target: self, action: #selector(cancel))
        let confirmButton = NSButton(title: "확인 후 Notion 교체", target: self, action: #selector(confirm))
        confirmButton.bezelColor = .systemBlue

        let controls = NSStackView(views: [colorWell, widthLabel, widthSlider, undoButton, clearButton, cancelButton, confirmButton])
        controls.orientation = .horizontal
        controls.spacing = 12
        controls.alignment = .centerY
        widthSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let stack = NSStackView(views: [titleLabel, canvasView, controls])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            canvasView.heightAnchor.constraint(greaterThanOrEqualToConstant: 560)
        ])
    }

    @objc
    private func changeColor(_ sender: NSColorWell) {
        canvasView.strokeColor = sender.color
    }

    @objc
    private func changeWidth(_ sender: NSSlider) {
        canvasView.strokeWidth = CGFloat(sender.doubleValue)
    }

    @objc
    private func undoStroke() {
        canvasView.undoLastStroke()
    }

    @objc
    private func clearAll() {
        canvasView.clearStrokes()
    }

    @objc
    private func cancel() {
        close()
    }

    @objc
    private func confirm() {
        onCommit(canvasView.renderedImage())
        close()
    }
}

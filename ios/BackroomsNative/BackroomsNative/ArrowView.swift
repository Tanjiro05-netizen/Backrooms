import UIKit

/// The compass arrow the web build points at tapes and the exit — the same
/// `M50 6 L82 62 L50 46 L18 62 Z` chevron, drawn as a path rather than shipped
/// as an asset so it stays crisp at any size and recolours in one place.
///
/// Rotation is applied by the caller as a transform, which is why the geometry
/// lives in `bounds` (transform-independent) rather than `frame`.
final class ArrowView: UIView {

    private let shape = CAShapeLayer()

    init(color: UIColor) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        shape.fillColor = color.cgColor
        layer.addSublayer(shape)
        // The HUD sits over a picture that is mostly beige wall; without a
        // shadow the arrow disappears into it exactly when you need it.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.75
        layer.shadowRadius = 3
        layer.shadowOffset = .zero
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        shape.frame = bounds
        let w = bounds.width, h = bounds.height
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0.50 * w, y: 0.06 * h))
        path.addLine(to: CGPoint(x: 0.82 * w, y: 0.62 * h))
        path.addLine(to: CGPoint(x: 0.50 * w, y: 0.46 * h))
        path.addLine(to: CGPoint(x: 0.18 * w, y: 0.62 * h))
        path.close()
        shape.path = path.cgPath
    }
}

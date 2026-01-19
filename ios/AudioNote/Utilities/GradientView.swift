import UIKit

extension UIColor {
    convenience init(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)

        self.init(
            red: CGFloat((rgb & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgb & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgb & 0x0000FF) / 255.0,
            alpha: 1.0
        )
    }
}

@IBDesignable
final class GradientView: UIView {

    // MARK: - Properties

    @IBInspectable var startColor: UIColor = UIColor(hex: "#1A1F60") {
        didSet { setNeedsDisplay() }
    }

    @IBInspectable var endColor: UIColor = UIColor(hex: "#4A2E8E") {
        didSet { setNeedsDisplay() }
    }

    @IBInspectable var startPoint: CGPoint = CGPoint(x: 0.5, y: 0) {
        didSet { setNeedsDisplay() }
    }

    @IBInspectable var endPoint: CGPoint = CGPoint(x: 0.5, y: 1) {
        didSet { setNeedsDisplay() }
    }

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        let colors = [startColor.cgColor, endColor.cgColor]
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors as CFArray,
                                        locations: [0.0, 1.0]) else { return }

        let startPoint = CGPoint(x: rect.width * self.startPoint.x, y: rect.height * self.startPoint.y)
        let endPoint = CGPoint(x: rect.width * self.endPoint.x, y: rect.height * self.endPoint.y)

        context.drawLinearGradient(gradient, start: startPoint, end: endPoint, options: [])
    }
}

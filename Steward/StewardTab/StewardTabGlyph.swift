import SwiftUI
import UIKit

/// The Steward tab's icon: the avatar's cat head filled with its eyes cut out, so it
/// sits beside the filled SF Symbols on the tab bar. Drawn from the same shapes as
/// the avatar and rendered as a template, so the tab bar tints it.
enum StewardTabGlyph {
    @MainActor static let image: UIImage = {
        let side: CGFloat = 26
        let rect = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: 1, dy: 1)
        // Filled with the eyes cut out, like the filled symbols beside it.
        let head = CatShape(eyeOpen: 1, small: true).path(in: rect)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor.black.setFill()
            let path = UIBezierPath(cgPath: head.cgPath)
            path.usesEvenOddFillRule = true
            path.fill()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }()
}

#if os(macOS)
    import AppKit
    import SwiftUI

    enum GoalongBrandAssets {
        static let menuBarImage: NSImage = {
            let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                let path = brandPath(in: rect.insetBy(dx: 1.2, dy: 2.2))
                path.lineWidth = 1.75
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                NSColor.labelColor.setStroke()
                path.stroke()
                return true
            }
            image.isTemplate = true
            image.accessibilityDescription = ProductIdentity.displayName
            return image
        }()

        /// The icon as a 3x bitmap that still reports 18 pt (144+ dpi), for the menu bar helper.
        /// `tiffRepresentation` of the drawing-handler image would give a 1x bitmap, blurry on Retina.
        /// Drawn once; the image never changes.
        static let menuBarImageData: Data = renderedTIFF(of: menuBarImage, scale: 3)

        static func renderedTIFF(of image: NSImage, scale: Int) -> Data {
            let pixelsWide = Int(image.size.width) * scale, pixelsHigh = Int(image.size.height) * scale
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: rep) else { return image.tiffRepresentation ?? Data() }
            rep.size = image.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            return rep.tiffRepresentation ?? image.tiffRepresentation ?? Data()
        }

        private static func brandPath(in rect: NSRect) -> NSBezierPath {
            let path = NSBezierPath()
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
            }

            path.move(to: point(0.08, 0.50))
            path.curve(
                to: point(0.51, 0.50),
                controlPoint1: point(0.08, 0.10),
                controlPoint2: point(0.37, 0.08)
            )
            path.curve(
                to: point(0.92, 0.50),
                controlPoint1: point(0.64, 0.92),
                controlPoint2: point(0.92, 0.90)
            )
            path.curve(
                to: point(0.51, 0.50),
                controlPoint1: point(0.92, 0.10),
                controlPoint2: point(0.64, 0.08)
            )
            path.curve(
                to: point(0.08, 0.50),
                controlPoint1: point(0.37, 0.92),
                controlPoint2: point(0.08, 0.90)
            )

            path.move(to: point(0.08, 0.50))
            path.line(to: point(0.39, 0.50))
            path.curve(
                to: point(0.49, 0.59),
                controlPoint1: point(0.44, 0.50),
                controlPoint2: point(0.49, 0.54)
            )
            return path
        }
    }

    struct GoalongMark: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
            }

            path.move(to: point(0.08, 0.50))
            path.addCurve(
                to: point(0.51, 0.50),
                control1: point(0.08, 0.10),
                control2: point(0.37, 0.08)
            )
            path.addCurve(
                to: point(0.92, 0.50),
                control1: point(0.64, 0.92),
                control2: point(0.92, 0.90)
            )
            path.addCurve(
                to: point(0.51, 0.50),
                control1: point(0.92, 0.10),
                control2: point(0.64, 0.08)
            )
            path.addCurve(
                to: point(0.08, 0.50),
                control1: point(0.37, 0.92),
                control2: point(0.08, 0.90)
            )
            path.move(to: point(0.08, 0.50))
            path.addLine(to: point(0.39, 0.50))
            path.addCurve(
                to: point(0.49, 0.59),
                control1: point(0.44, 0.50),
                control2: point(0.49, 0.54)
            )
            return path
        }
    }
#endif

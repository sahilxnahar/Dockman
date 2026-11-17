import AppKit
import ConfigKit

// Pure screen geometry for Dock windows (placement, reveal strip, hide offset).
extension DockController {
    /// Translation that tucks the contents against (into) the Dock's screen edge.
    static func hiddenOffset(edge: Appearance.Edge, size: NSSize) -> CATransform3D {
        switch edge {
        case .bottom: return CATransform3DMakeTranslation(0, -size.height * 0.6, 0)
        case .top:    return CATransform3DMakeTranslation(0, size.height * 0.6, 0)
        case .left:   return CATransform3DMakeTranslation(-size.width * 0.6, 0, 0)
        case .right:  return CATransform3DMakeTranslation(size.width * 0.6, 0, 0)
        }
    }
    /// The thin edge strip whose entry reveals a hidden Dock.
    static func revealZone(edge: Appearance.Edge, revealed: NSRect, screenFrame s: NSRect) -> NSRect {
        let t: CGFloat = 4
        switch edge {
        case .bottom: return NSRect(x: revealed.minX - 8, y: s.minY, width: revealed.width + 16, height: t)
        case .top:    return NSRect(x: revealed.minX - 8, y: s.maxY - t, width: revealed.width + 16, height: t)
        case .left:   return NSRect(x: s.minX, y: revealed.minY - 8, width: t, height: revealed.height + 16)
        case .right:  return NSRect(x: s.maxX - t, y: revealed.minY - 8, width: t, height: revealed.height + 16)
        }
    }
    static func frame(for appearance: Appearance, size: NSSize, screenFrame f: NSRect) -> NSRect {
        let margin = CGFloat(appearance.edgeGap)
        // Never let the Dock exceed its own display, or it would spill onto an
        // adjacent one (one desktop's dock must never appear on another).
        let w = min(size.width, f.width)
        let h = min(size.height, f.height)
        var rect: NSRect
        if appearance.floating {
            return NSRect(x: f.minX + (f.width - w) * appearance.floatX,
                          y: f.minY + (f.height - h) * appearance.floatY, width: w, height: h)
        }
        // Position along the edge: start = left (horizontal) or top (vertical).
        let inset = max(margin, 8)
        let x: CGFloat, y: CGFloat
        switch appearance.alignment {
        case .start:  x = f.minX + inset;          y = f.maxY - inset - h
        case .center: x = f.midX - w / 2;          y = f.midY - h / 2
        case .end:    x = f.maxX - inset - w;      y = f.minY + inset
        }
        switch appearance.edge {
        case .bottom: rect = NSRect(x: x, y: f.minY + margin, width: w, height: h)
        case .top:    rect = NSRect(x: x, y: f.maxY - margin - h, width: w, height: h)
        case .left:   rect = NSRect(x: f.minX + margin, y: y, width: w, height: h)
        case .right:  rect = NSRect(x: f.maxX - margin - w, y: y, width: w, height: h)
        }
        // Clamp fully inside the display bounds as a final safety net.
        rect.origin.x = min(max(rect.origin.x, f.minX), f.maxX - w)
        rect.origin.y = min(max(rect.origin.y, f.minY), f.maxY - h)
        return rect
    }
}

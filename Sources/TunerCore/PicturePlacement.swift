import Foundation

/// Where the small floating picture may sit on a screen. Rectangles are in screen coordinates.
public enum PicturePlacement {
    /// `frame` moved the least that puts all of it inside `screen`. A frame larger than the screen
    /// is held to the screen's left and top edges, where its controls are.
    public static func kept(_ frame: CGRect, on screen: CGRect) -> CGRect {
        var kept = frame
        kept.origin.x = min(max(frame.minX, screen.minX), max(screen.minX, screen.maxX - frame.width))
        kept.origin.y = max(min(frame.minY, screen.maxY - frame.height), min(screen.minY, screen.maxY - frame.height))
        return kept
    }

    /// `frame` moved into the corner of `screen` its centre is nearest, `margin` in from both edges.
    public static func snapped(_ frame: CGRect, on screen: CGRect, margin: CGFloat) -> CGRect {
        var snapped = frame
        snapped.origin.x = frame.midX < screen.midX ? screen.minX + margin : screen.maxX - frame.width - margin
        snapped.origin.y = frame.midY < screen.midY ? screen.minY + margin : screen.maxY - frame.height - margin
        return kept(snapped, on: screen)
    }
}

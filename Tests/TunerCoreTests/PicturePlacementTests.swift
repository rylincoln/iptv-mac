import Foundation
import Testing
@testable import TunerCore

/// A screen whose usable area starts off the origin, as one beside another display does.
private let screen = CGRect(x: 100, y: 50, width: 1600, height: 900)

private func picture(x: CGFloat, y: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: 480, height: 270)
}

@Suite struct PicturePlacementTests {
    @Test func aPictureInsideTheScreenStaysWhereItIs() {
        #expect(PicturePlacement.kept(picture(x: 600, y: 400), on: screen) == picture(x: 600, y: 400))
    }

    @Test func aPictureDraggedOffAnEdgeIsHeldAtThatEdge() {
        #expect(PicturePlacement.kept(picture(x: -50, y: 400), on: screen) == picture(x: 100, y: 400))
        #expect(PicturePlacement.kept(picture(x: 1500, y: 400), on: screen) == picture(x: 1220, y: 400))
        #expect(PicturePlacement.kept(picture(x: 600, y: -20), on: screen) == picture(x: 600, y: 50))
        #expect(PicturePlacement.kept(picture(x: 600, y: 900), on: screen) == picture(x: 600, y: 680))
        #expect(PicturePlacement.kept(picture(x: 5000, y: 5000), on: screen) == picture(x: 1220, y: 680))
    }

    @Test func aPictureLargerThanTheScreenKeepsItsTopLeftCornerOnIt() {
        let large = CGRect(x: 700, y: 300, width: 2000, height: 1200)
        let kept = PicturePlacement.kept(large, on: screen)
        #expect(kept.minX == screen.minX)
        #expect(kept.maxY == screen.maxY)
    }

    @Test func itSnapsToTheCornerItsCentreIsNearest() {
        // Bottom left, bottom right, top left, top right (y runs upwards).
        #expect(PicturePlacement.snapped(picture(x: 300, y: 100), on: screen, margin: 20) == picture(x: 120, y: 70))
        #expect(PicturePlacement.snapped(picture(x: 900, y: 100), on: screen, margin: 20) == picture(x: 1200, y: 70))
        #expect(PicturePlacement.snapped(picture(x: 300, y: 500), on: screen, margin: 20) == picture(x: 120, y: 660))
        #expect(PicturePlacement.snapped(picture(x: 900, y: 500), on: screen, margin: 20) == picture(x: 1200, y: 660))
    }

    @Test func snappingKeepsAPictureTooLargeForItsMarginsOnTheScreen() {
        let wide = CGRect(x: 200, y: 100, width: 1590, height: 270)
        let snapped = PicturePlacement.snapped(wide, on: screen, margin: 20)
        #expect(snapped.minX >= screen.minX)
        #expect(snapped.maxX <= screen.maxX)
    }
}

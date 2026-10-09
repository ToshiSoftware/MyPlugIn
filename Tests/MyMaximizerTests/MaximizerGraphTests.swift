import SwiftUI
import XCTest
@testable import MyMaximizer

/// The history graph scrolls by whole pixels: after one more point, the
/// picture is the previous one moved left by exactly one point.
@MainActor
final class MaximizerGraphTests: XCTestCase {
    private func pixels(_ columns: [MaximizerColumn], merge: Int) throws -> (data: [UInt8], width: Int, height: Int) {
        let graph = MaximizerGraph(columns: columns, firstIndex: 0, merge: merge, ceiling: -0.1, threshold: -6)
            .frame(width: CGFloat(MaximizerHistory.viewColumns), height: 120)
            .environment(\.displayScale, 2)
        let renderer = ImageRenderer(content: graph)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (data, width, height)
    }

    func testScrollingMovesWholePixels() throws {
        let columns = (0..<2_000).map { index -> MaximizerColumn in
            let phase = Double(index)
            return MaximizerColumn(peak: Float(0.2 + 0.7 * abs(sin(phase * 0.05))),
                                   reduction: -Float(4 * abs(sin(phase * 0.031))),
                                   boost: Float(1 + sin(phase * 0.02)))
        }
        for merge in [1, 2, 4] {
            let count = 1_100
            let before = try pixels(Array(columns[..<count]), merge: merge)
            // An odd number of columns: the old grouping would have shifted.
            let after = try pixels(Array(columns[..<(count + merge + 1)]), merge: merge)
            // Complete new points, one point (2 px at scale 2) each.
            let shift = 2 * ((count + merge + 1) / merge - count / merge)
            var differences = 0
            // Leave out the scale labels (left) and the dotted lines (top, THRESH at -6 dB).
            for y in 30..<230 where !(44...54).contains(y) {
                for x in 60..<(before.width - shift) {
                    for channel in 0..<4 {
                        let old = before.data[(y * before.width + x + shift) * 4 + channel]
                        let new = after.data[(y * after.width + x) * 4 + channel]
                        if old != new { differences += 1 }
                    }
                }
            }
            XCTAssertEqual(differences, 0, "merge \(merge)")
        }
    }
}

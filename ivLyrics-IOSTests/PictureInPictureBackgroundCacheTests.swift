import UIKit
import XCTest
@testable import ivLyrics_IOS

@MainActor
final class PictureInPictureBackgroundCacheTests: XCTestCase {
    func testStaticBackgroundCachePreservesPixelsAndReusesImage() throws {
        let controller = LyricsPictureInPictureController()
        let orientations = [
            AppSettings.pipOrientationLandscape,
            AppSettings.pipOrientationPortrait,
            AppSettings.pipOrientationSquare
        ]
        let modes = [AppSettings.pipBackgroundGradient, AppSettings.pipBackgroundSolid]

        for orientation in orientations {
            for mode in modes {
                controller.debugResetStaticBackgroundCache()
                let reference = controller.debugStaticBackgroundImage(
                    orientation: orientation,
                    backgroundMode: mode,
                    solidColor: "#2457A6",
                    useCache: false
                )
                let firstCachedRender = controller.debugStaticBackgroundImage(
                    orientation: orientation,
                    backgroundMode: mode,
                    solidColor: "#2457A6"
                )
                XCTAssertEqual(controller.debugStaticBackgroundCacheHitCount, 0)
                let cacheHitRender = controller.debugStaticBackgroundImage(
                    orientation: orientation,
                    backgroundMode: mode,
                    solidColor: "#2457A6"
                )
                XCTAssertEqual(controller.debugStaticBackgroundCacheHitCount, 1)

                let identifier = "\(orientation)-\(mode)"
                XCTAssertLessThanOrEqual(
                    try meanPixelDifference(reference, firstCachedRender),
                    1,
                    "cache miss changed pixels for \(identifier)"
                )
                XCTAssertLessThanOrEqual(
                    try meanPixelDifference(reference, cacheHitRender),
                    1,
                    "cache hit changed pixels for \(identifier)"
                )
            }
        }
    }

    private func meanPixelDifference(_ lhs: UIImage, _ rhs: UIImage) throws -> Double {
        let lhsPixels = try rgbaPixels(lhs)
        let rhsPixels = try rgbaPixels(rhs)
        XCTAssertEqual(lhsPixels.width, rhsPixels.width)
        XCTAssertEqual(lhsPixels.height, rhsPixels.height)
        guard lhsPixels.bytes.count == rhsPixels.bytes.count else {
            throw PixelComparisonError.sizeMismatch
        }
        let difference = zip(lhsPixels.bytes, rhsPixels.bytes).reduce(0.0) { total, pair in
            total + Double(abs(Int(pair.0) - Int(pair.1)))
        }
        return difference / Double(lhsPixels.bytes.count)
    }

    private func rgbaPixels(_ image: UIImage) throws -> (bytes: [UInt8], width: Int, height: Int) {
        guard let cgImage = image.cgImage else { throw PixelComparisonError.missingCGImage }
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw PixelComparisonError.contextCreationFailed }
        return (bytes, width, height)
    }

    private enum PixelComparisonError: Error {
        case missingCGImage
        case contextCreationFailed
        case sizeMismatch
    }
}

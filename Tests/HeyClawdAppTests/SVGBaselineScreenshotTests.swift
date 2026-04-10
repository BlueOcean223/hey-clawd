import AppKit
import CoreGraphics
import QuartzCore
import XCTest
@testable import HeyClawdApp

@MainActor
final class SVGBaselineScreenshotTests: XCTestCase {
    private struct SVGFixture {
        let filename: String
        let markup: String
    }

    private struct ScreenshotResult {
        let svgFile: String
        let pngFile: String
        let size: CGSize
        let status: String
    }

    func testGenerateBaselineScreenshots() throws {
        let fileManager = FileManager.default
        let fixtures = try loadAllSVGFixtures()

        XCTAssertEqual(fixtures.count, 51, "Expected 51 SVG files in Resources/svg.")

        let outputDirectory = try XCTUnwrap(
            projectRoot()?
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("phases", isDirectory: true)
                .appendingPathComponent("core-animation-migration", isDirectory: true)
                .appendingPathComponent("artifacts", isDirectory: true)
                .appendingPathComponent("baseline-screenshots", isDirectory: true),
            "Could not determine project root."
        )

        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let renderSize = CGSize(width: 400, height: 400)
        var results: [ScreenshotResult] = []
        var failures: [String] = []
        var successCount = 0

        for fixture in fixtures {
            let pngFilename = fixture.filename.replacingOccurrences(of: ".svg", with: ".png")
            let pngURL = outputDirectory.appendingPathComponent(pngFilename, isDirectory: false)

            let document = SVGParser.parse(fixture.markup)
            let rootLayer = CALayerRenderer.build(document)
            let sourceBounds = rootLayer.bounds
            CAAnimationBuilder.apply(document, to: rootLayer)
            let scaleX = renderSize.width / max(sourceBounds.width, 1)
            let scaleY = renderSize.height / max(sourceBounds.height, 1)
            rootLayer.setValue(scaleX, forKey: "baselineRenderScaleX")
            rootLayer.setValue(scaleY, forKey: "baselineRenderScaleY")
            rootLayer.frame = CGRect(origin: .zero, size: renderSize)

            guard let pngData = renderLayerToPNG(layer: rootLayer, size: renderSize) else {
                failures.append("\(fixture.filename): failed to render PNG")
                results.append(
                    ScreenshotResult(
                        svgFile: fixture.filename,
                        pngFile: pngFilename,
                        size: renderSize,
                        status: "Render failed"
                    )
                )
                continue
            }

            do {
                try pngData.write(to: pngURL, options: .atomic)
                successCount += 1
                results.append(
                    ScreenshotResult(
                        svgFile: fixture.filename,
                        pngFile: pngFilename,
                        size: renderSize,
                        status: "Generated"
                    )
                )
            } catch {
                failures.append("\(fixture.filename): failed to write PNG (\(error.localizedDescription))")
                results.append(
                    ScreenshotResult(
                        svgFile: fixture.filename,
                        pngFile: pngFilename,
                        size: renderSize,
                        status: "Write failed"
                    )
                )
            }
        }

        try writeIndexMarkdown(results: results, to: outputDirectory)

        print(
            "SVGBaselineScreenshotTests: generated \(successCount)/\(fixtures.count) screenshots at \(outputDirectory.path)"
        )

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    private func renderLayerToPNG(layer: CALayer, size: CGSize) -> Data? {
        let width = Int(size.width)
        let height = Int(size.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        let renderRect = CGRect(origin: .zero, size: size)
        context.clear(renderRect)
        layer.layoutIfNeeded()
        layer.displayIfNeeded()
        let scaleX = layer.value(forKey: "baselineRenderScaleX") as? CGFloat ?? 1
        let scaleY = layer.value(forKey: "baselineRenderScaleY") as? CGFloat ?? 1
        context.saveGState()
        // CALayer with isGeometryFlipped=true uses Y-down; CGContext is Y-up.
        // Flip context so the rendered image matches screen orientation.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: scaleX, y: -scaleY)
        layer.render(in: context)
        context.restoreGState()

        guard let image = context.makeImage() else {
            return nil
        }

        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .png, properties: [:])
    }

    private func projectRoot() -> URL? {
        let fileManager = FileManager.default
        var currentURL = Bundle(for: Self.self).bundleURL.resolvingSymlinksInPath()

        while true {
            let packageURL = currentURL.appendingPathComponent("Package.swift", isDirectory: false)
            if fileManager.fileExists(atPath: packageURL.path) {
                return currentURL
            }

            let parentURL = currentURL.deletingLastPathComponent()
            if parentURL == currentURL {
                return nil
            }
            currentURL = parentURL
        }
    }

    private func svgDirectory() -> URL? {
        projectRoot()?
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("svg", isDirectory: true)
    }

    private func loadAllSVGFixtures() throws -> [SVGFixture] {
        let svgDirectory = try XCTUnwrap(svgDirectory(), "Could not locate Resources/svg.")
        let filenames = try FileManager.default.contentsOfDirectory(atPath: svgDirectory.path)
            .filter { $0.hasSuffix(".svg") }
            .sorted()

        return try filenames.map { filename in
            let fileURL = svgDirectory.appendingPathComponent(filename, isDirectory: false)
            let markup = try String(contentsOf: fileURL, encoding: .utf8)
            return SVGFixture(filename: filename, markup: markup)
        }
    }

    private func writeIndexMarkdown(results: [ScreenshotResult], to outputDirectory: URL) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var markdown = "# SVG Baseline Screenshots (Core Animation Pipeline)\n\n"
        markdown += "Generated: \(formatter.string(from: Date()))\n\n"
        markdown += "| SVG File | Screenshot | Size | Status |\n"
        markdown += "| --- | --- | --- | --- |\n"

        for result in results {
            let sizeLabel = "\(Int(result.size.width))x\(Int(result.size.height))"
            markdown += "| \(result.svgFile) | [\(result.pngFile)](\(result.pngFile)) | \(sizeLabel) | \(result.status) |\n"
        }

        let indexURL = outputDirectory.appendingPathComponent("index.md", isDirectory: false)
        try markdown.write(to: indexURL, atomically: true, encoding: .utf8)
    }
}

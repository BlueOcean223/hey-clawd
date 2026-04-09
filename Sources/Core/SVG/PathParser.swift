import Foundation
import CoreGraphics

enum PathParser {
    static func parsePath(_ d: String) -> CGPath? {
        guard !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        var scanner = Scanner(d)
        let path = CGMutablePath()

        var currentPoint = CGPoint.zero
        var subpathStart = CGPoint.zero
        var hasCurrentPoint = false
        var activeCommand: Character?
        var lastCommand: Character?
        var lastCubicControl: CGPoint?
        var lastQuadraticControl: CGPoint?

        while scanner.hasMoreData {
            if let command = scanner.readCommand() {
                activeCommand = command
            } else {
                guard let command = activeCommand,
                      command != "Z",
                      command != "z" else {
                    return nil
                }
            }

            guard let command = activeCommand else {
                return nil
            }

            switch command {
            case "M", "m":
                guard let rawPoint = scanner.readPoint() else {
                    return nil
                }

                let basePoint = hasCurrentPoint ? currentPoint : .zero
                let movePoint = command == "M" ? rawPoint : basePoint.offsetBy(dx: rawPoint.x, dy: rawPoint.y)
                path.move(to: movePoint)
                currentPoint = movePoint
                subpathStart = movePoint
                hasCurrentPoint = true
                lastCubicControl = nil
                lastQuadraticControl = nil
                lastCommand = command

                while scanner.hasNumberAhead {
                    guard let rawLinePoint = scanner.readPoint() else {
                        return nil
                    }

                    let linePoint = command == "M"
                        ? rawLinePoint
                        : currentPoint.offsetBy(dx: rawLinePoint.x, dy: rawLinePoint.y)
                    path.addLine(to: linePoint)
                    currentPoint = linePoint
                    lastCommand = command == "M" ? "L" : "l"
                }
            case "L", "l":
                guard hasCurrentPoint else {
                    return nil
                }

                var didReadSegment = false
                while scanner.hasNumberAhead {
                    guard let rawPoint = scanner.readPoint() else {
                        return nil
                    }

                    let point = command == "L"
                        ? rawPoint
                        : currentPoint.offsetBy(dx: rawPoint.x, dy: rawPoint.y)
                    path.addLine(to: point)
                    currentPoint = point
                    didReadSegment = true
                }

                guard didReadSegment else {
                    return nil
                }

                lastCubicControl = nil
                lastQuadraticControl = nil
                lastCommand = command
            case "H", "h":
                guard hasCurrentPoint else {
                    return nil
                }

                var didReadSegment = false
                while scanner.hasNumberAhead {
                    guard let value = scanner.readNumber() else {
                        return nil
                    }

                    let x = command == "H" ? value : currentPoint.x + value
                    let point = CGPoint(x: x, y: currentPoint.y)
                    path.addLine(to: point)
                    currentPoint = point
                    didReadSegment = true
                }

                guard didReadSegment else {
                    return nil
                }

                lastCubicControl = nil
                lastQuadraticControl = nil
                lastCommand = command
            case "V", "v":
                guard hasCurrentPoint else {
                    return nil
                }

                var didReadSegment = false
                while scanner.hasNumberAhead {
                    guard let value = scanner.readNumber() else {
                        return nil
                    }

                    let y = command == "V" ? value : currentPoint.y + value
                    let point = CGPoint(x: currentPoint.x, y: y)
                    path.addLine(to: point)
                    currentPoint = point
                    didReadSegment = true
                }

                guard didReadSegment else {
                    return nil
                }

                lastCubicControl = nil
                lastQuadraticControl = nil
                lastCommand = command
            case "C", "c":
                guard hasCurrentPoint else {
                    return nil
                }

                var didReadSegment = false
                while scanner.hasNumberAhead {
                    guard let rawControl1 = scanner.readPoint(),
                          let rawControl2 = scanner.readPoint(),
                          let rawEndPoint = scanner.readPoint() else {
                        return nil
                    }

                    let control1 = command == "C"
                        ? rawControl1
                        : currentPoint.offsetBy(dx: rawControl1.x, dy: rawControl1.y)
                    let control2 = command == "C"
                        ? rawControl2
                        : currentPoint.offsetBy(dx: rawControl2.x, dy: rawControl2.y)
                    let endPoint = command == "C"
                        ? rawEndPoint
                        : currentPoint.offsetBy(dx: rawEndPoint.x, dy: rawEndPoint.y)

                    path.addCurve(to: endPoint, control1: control1, control2: control2)
                    currentPoint = endPoint
                    lastCubicControl = control2
                    lastQuadraticControl = nil
                    didReadSegment = true
                }

                guard didReadSegment else {
                    return nil
                }

                lastCommand = command
            case "S", "s":
                guard hasCurrentPoint else {
                    return nil
                }

                var didReadSegment = false
                while scanner.hasNumberAhead {
                    guard let rawControl2 = scanner.readPoint(),
                          let rawEndPoint = scanner.readPoint() else {
                        return nil
                    }

                    let control1: CGPoint
                    if let lastCubicControl,
                       lastCommand == "C" || lastCommand == "c" || lastCommand == "S" || lastCommand == "s" {
                        control1 = currentPoint.reflected(around: lastCubicControl)
                    } else {
                        control1 = currentPoint
                    }

                    let control2 = command == "S"
                        ? rawControl2
                        : currentPoint.offsetBy(dx: rawControl2.x, dy: rawControl2.y)
                    let endPoint = command == "S"
                        ? rawEndPoint
                        : currentPoint.offsetBy(dx: rawEndPoint.x, dy: rawEndPoint.y)

                    path.addCurve(to: endPoint, control1: control1, control2: control2)
                    currentPoint = endPoint
                    lastCubicControl = control2
                    lastQuadraticControl = nil
                    didReadSegment = true
                }

                guard didReadSegment else {
                    return nil
                }

                lastCommand = command
            case "Q", "q":
                guard hasCurrentPoint else {
                    return nil
                }

                var didReadSegment = false
                while scanner.hasNumberAhead {
                    guard let rawControl = scanner.readPoint(),
                          let rawEndPoint = scanner.readPoint() else {
                        return nil
                    }

                    let control = command == "Q"
                        ? rawControl
                        : currentPoint.offsetBy(dx: rawControl.x, dy: rawControl.y)
                    let endPoint = command == "Q"
                        ? rawEndPoint
                        : currentPoint.offsetBy(dx: rawEndPoint.x, dy: rawEndPoint.y)

                    path.addQuadCurve(to: endPoint, control: control)
                    currentPoint = endPoint
                    lastQuadraticControl = control
                    lastCubicControl = nil
                    didReadSegment = true
                }

                guard didReadSegment else {
                    return nil
                }

                lastCommand = command
            case "T", "t":
                guard hasCurrentPoint else {
                    return nil
                }

                var didReadSegment = false
                while scanner.hasNumberAhead {
                    guard let rawEndPoint = scanner.readPoint() else {
                        return nil
                    }

                    let control: CGPoint
                    if let lastQuadraticControl,
                       lastCommand == "Q" || lastCommand == "q" || lastCommand == "T" || lastCommand == "t" {
                        control = currentPoint.reflected(around: lastQuadraticControl)
                    } else {
                        control = currentPoint
                    }

                    let endPoint = command == "T"
                        ? rawEndPoint
                        : currentPoint.offsetBy(dx: rawEndPoint.x, dy: rawEndPoint.y)

                    path.addQuadCurve(to: endPoint, control: control)
                    currentPoint = endPoint
                    lastQuadraticControl = control
                    lastCubicControl = nil
                    didReadSegment = true
                }

                guard didReadSegment else {
                    return nil
                }

                lastCommand = command
            case "A", "a":
                guard hasCurrentPoint else {
                    return nil
                }

                var didReadSegment = false
                while scanner.hasNumberAhead {
                    guard let rawRadiusX = scanner.readNumber(),
                          let rawRadiusY = scanner.readNumber(),
                          let rotation = scanner.readNumber(),
                          let largeArc = scanner.readFlag(),
                          let sweep = scanner.readFlag(),
                          let rawEndPoint = scanner.readPoint() else {
                        return nil
                    }

                    let endPoint = command == "A"
                        ? rawEndPoint
                        : currentPoint.offsetBy(dx: rawEndPoint.x, dy: rawEndPoint.y)

                    addArc(
                        to: path,
                        from: currentPoint,
                        to: endPoint,
                        radiusX: rawRadiusX,
                        radiusY: rawRadiusY,
                        xAxisRotation: rotation,
                        largeArc: largeArc,
                        sweep: sweep
                    )
                    currentPoint = endPoint
                    lastCubicControl = nil
                    lastQuadraticControl = nil
                    didReadSegment = true
                }

                guard didReadSegment else {
                    return nil
                }

                lastCommand = command
            case "Z", "z":
                guard hasCurrentPoint else {
                    return nil
                }

                path.closeSubpath()
                currentPoint = subpathStart
                lastCubicControl = nil
                lastQuadraticControl = nil
                lastCommand = command
            default:
                return nil
            }
        }

        return path.isEmpty ? nil : path.copy()
    }

    static func parsePolygonPoints(_ points: String) -> CGPath? {
        parsePoints(points, closeSubpath: true)
    }

    static func parsePolylinePoints(_ points: String) -> CGPath? {
        parsePoints(points, closeSubpath: false)
    }

    private static func parsePoints(_ points: String, closeSubpath: Bool) -> CGPath? {
        guard !points.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        var scanner = Scanner(points)
        var parsedPoints: [CGPoint] = []

        while scanner.hasMoreData {
            guard let point = scanner.readPoint() else {
                return nil
            }
            parsedPoints.append(point)
        }

        guard parsedPoints.count >= 2 else {
            return nil
        }

        let path = CGMutablePath()
        path.move(to: parsedPoints[0])
        for point in parsedPoints.dropFirst() {
            path.addLine(to: point)
        }

        if closeSubpath {
            path.closeSubpath()
        }

        return path.copy()
    }

    private static func addArc(
        to path: CGMutablePath,
        from start: CGPoint,
        to end: CGPoint,
        radiusX: CGFloat,
        radiusY: CGFloat,
        xAxisRotation: CGFloat,
        largeArc: Bool,
        sweep: Bool
    ) {
        if start == end {
            return
        }

        var rx = abs(radiusX)
        var ry = abs(radiusY)
        guard rx > 0, ry > 0 else {
            path.addLine(to: end)
            return
        }

        let rotationAngle = xAxisRotation * .pi / 180
        let cosAngle = cos(rotationAngle)
        let sinAngle = sin(rotationAngle)

        let deltaX = (start.x - end.x) / 2
        let deltaY = (start.y - end.y) / 2

        let x1Prime = cosAngle * deltaX + sinAngle * deltaY
        let y1Prime = -sinAngle * deltaX + cosAngle * deltaY

        let x1PrimeSquared = x1Prime * x1Prime
        let y1PrimeSquared = y1Prime * y1Prime

        let radiiScale = x1PrimeSquared / (rx * rx) + y1PrimeSquared / (ry * ry)
        if radiiScale > 1 {
            let scale = sqrt(radiiScale)
            rx *= scale
            ry *= scale
        }

        let rxSquared = rx * rx
        let rySquared = ry * ry

        let numerator = max(
            0,
            rxSquared * rySquared - rxSquared * y1PrimeSquared - rySquared * x1PrimeSquared
        )
        let denominator = rxSquared * y1PrimeSquared + rySquared * x1PrimeSquared

        guard denominator > 0 else {
            path.addLine(to: end)
            return
        }

        let direction: CGFloat = largeArc == sweep ? -1 : 1
        let factor = direction * sqrt(numerator / denominator)

        let centerPrime = CGPoint(
            x: factor * (rx * y1Prime / ry),
            y: factor * (-ry * x1Prime / rx)
        )

        let center = CGPoint(
            x: cosAngle * centerPrime.x - sinAngle * centerPrime.y + (start.x + end.x) / 2,
            y: sinAngle * centerPrime.x + cosAngle * centerPrime.y + (start.y + end.y) / 2
        )

        let startVector = CGPoint(
            x: (x1Prime - centerPrime.x) / rx,
            y: (y1Prime - centerPrime.y) / ry
        )
        let endVector = CGPoint(
            x: (-x1Prime - centerPrime.x) / rx,
            y: (-y1Prime - centerPrime.y) / ry
        )

        var startAngle = atan2(startVector.y, startVector.x)
        var deltaAngle = angle(from: startVector, to: endVector)

        if !sweep, deltaAngle > 0 {
            deltaAngle -= 2 * .pi
        } else if sweep, deltaAngle < 0 {
            deltaAngle += 2 * .pi
        }

        let segmentCount = max(1, Int(ceil(abs(deltaAngle) / (.pi / 2))))
        let segmentAngle = deltaAngle / CGFloat(segmentCount)

        for _ in 0..<segmentCount {
            let endAngle = startAngle + segmentAngle
            addArcSegment(
                to: path,
                center: center,
                radiusX: rx,
                radiusY: ry,
                rotation: rotationAngle,
                startAngle: startAngle,
                endAngle: endAngle
            )
            startAngle = endAngle
        }
    }

    private static func addArcSegment(
        to path: CGMutablePath,
        center: CGPoint,
        radiusX: CGFloat,
        radiusY: CGFloat,
        rotation: CGFloat,
        startAngle: CGFloat,
        endAngle: CGFloat
    ) {
        let delta = endAngle - startAngle
        let alpha = (4 / 3) * tan(delta / 4)

        let startSin = sin(startAngle)
        let startCos = cos(startAngle)
        let endSin = sin(endAngle)
        let endCos = cos(endAngle)

        let point1 = CGPoint(
            x: radiusX * (startCos - alpha * startSin),
            y: radiusY * (startSin + alpha * startCos)
        )
        let point2 = CGPoint(
            x: radiusX * (endCos + alpha * endSin),
            y: radiusY * (endSin - alpha * endCos)
        )
        let endPoint = CGPoint(
            x: radiusX * endCos,
            y: radiusY * endSin
        )

        path.addCurve(
            to: transformedEllipsePoint(endPoint, center: center, rotation: rotation),
            control1: transformedEllipsePoint(point1, center: center, rotation: rotation),
            control2: transformedEllipsePoint(point2, center: center, rotation: rotation)
        )
    }

    private static func transformedEllipsePoint(
        _ point: CGPoint,
        center: CGPoint,
        rotation: CGFloat
    ) -> CGPoint {
        let cosRotation = cos(rotation)
        let sinRotation = sin(rotation)
        return CGPoint(
            x: center.x + cosRotation * point.x - sinRotation * point.y,
            y: center.y + sinRotation * point.x + cosRotation * point.y
        )
    }

    private static func angle(from start: CGPoint, to end: CGPoint) -> CGFloat {
        atan2(start.x * end.y - start.y * end.x, start.x * end.x + start.y * end.y)
    }
}

private extension PathParser {
    struct Scanner {
        private let scalars: [UnicodeScalar]
        private var index = 0

        init(_ text: String) {
            scalars = Array(text.unicodeScalars)
        }

        var hasMoreData: Bool {
            mutating get {
                skipSeparators()
                return index < scalars.count
            }
        }

        var hasNumberAhead: Bool {
            mutating get {
                skipSeparators()
                guard index < scalars.count else {
                    return false
                }
                return isNumberStart(scalars[index])
            }
        }

        mutating func readCommand() -> Character? {
            skipSeparators()
            guard index < scalars.count else {
                return nil
            }

            let scalar = scalars[index]
            guard isCommand(scalar) else {
                return nil
            }

            index += 1
            return Character(scalar)
        }

        mutating func readPoint() -> CGPoint? {
            guard let x = readNumber(),
                  let y = readNumber() else {
                return nil
            }
            return CGPoint(x: x, y: y)
        }

        mutating func readFlag() -> Bool? {
            skipSeparators()
            guard index < scalars.count else {
                return nil
            }

            switch scalars[index] {
            case "0":
                index += 1
                return false
            case "1":
                index += 1
                return true
            default:
                return nil
            }
        }

        mutating func readNumber() -> CGFloat? {
            skipSeparators()
            guard index < scalars.count else {
                return nil
            }

            let startIndex = index

            if scalars[index] == "+" || scalars[index] == "-" {
                index += 1
            }

            var hasDigits = false
            while index < scalars.count, scalars[index].isASCIIDigit {
                index += 1
                hasDigits = true
            }

            if index < scalars.count, scalars[index] == "." {
                index += 1
                while index < scalars.count, scalars[index].isASCIIDigit {
                    index += 1
                    hasDigits = true
                }
            }

            guard hasDigits else {
                index = startIndex
                return nil
            }

            if index < scalars.count, scalars[index] == "e" || scalars[index] == "E" {
                let exponentIndex = index
                index += 1

                if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" {
                    index += 1
                }

                let exponentStart = index
                while index < scalars.count, scalars[index].isASCIIDigit {
                    index += 1
                }

                if exponentStart == index {
                    index = exponentIndex
                }
            }

            let scalarView = String.UnicodeScalarView(scalars[startIndex..<index])
            guard let value = Double(String(scalarView)),
                  value.isFinite else {
                index = startIndex
                return nil
            }

            return CGFloat(value)
        }

        private mutating func skipSeparators() {
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar == "," || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    index += 1
                    continue
                }
                break
            }
        }

        private func isCommand(_ scalar: UnicodeScalar) -> Bool {
            switch scalar {
            case "M", "m", "L", "l", "H", "h", "V", "v",
                 "C", "c", "S", "s", "Q", "q", "T", "t",
                 "A", "a", "Z", "z":
                return true
            default:
                return false
            }
        }

        private func isNumberStart(_ scalar: UnicodeScalar) -> Bool {
            scalar == "+" || scalar == "-" || scalar == "." || scalar.isASCIIDigit
        }
    }
}

private extension CGPoint {
    func offsetBy(dx: CGFloat, dy: CGFloat) -> CGPoint {
        CGPoint(x: x + dx, y: y + dy)
    }

    func reflected(around point: CGPoint) -> CGPoint {
        CGPoint(x: (2 * x) - point.x, y: (2 * y) - point.y)
    }
}

private extension UnicodeScalar {
    var isASCIIDigit: Bool {
        value >= 48 && value <= 57
    }
}

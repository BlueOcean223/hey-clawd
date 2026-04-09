import Darwin
import Foundation
import XCTest
@testable import HeyClawdApp

final class HTTPServerTests: XCTestCase {
    func testAttachAfterDisconnectImmediatelyDeniesAndRunsDisconnectHandler() async {
        let result = await HTTPServerTestSupport.attachAfterDisconnectResult()

        XCTAssertEqual(result.behavior.rawValue, PermissionBehavior.deny.rawValue)
        XCTAssertTrue(result.disconnectHandlerCalled)
    }

    func testPermissionDisconnectAfterSocketHalfCloseCancelsPendingRequest() async throws {
        let server = HTTPServer()
        defer { server.stop() }

        let requestHandled = expectation(description: "permission handler invoked")
        let disconnected = expectation(description: "client disconnect observed")

        server.setPermissionRequestHandler { request in
            request.setDisconnectHandler {
                disconnected.fulfill()
            }
            requestHandled.fulfill()
        }

        let startedPort = await server.start()
        let port = try XCTUnwrap(startedPort)
        let socketFD = try makeSocket(port: port)
        defer { close(socketFD) }

        let body = Data("{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sleep 30\"},\"session_id\":\"test-disconnect\"}".utf8)
        let headerLines = [
            "POST /permission HTTP/1.1",
            "Host: 127.0.0.1",
            "Content-Type: application/json",
            "Content-Length: \(body.count)",
            "",
            "",
        ]

        var request = Data(headerLines.joined(separator: "\r\n").utf8)
        request.append(body)

        try writeAll(request, to: socketFD)
        await fulfillment(of: [requestHandled], timeout: 1.0)

        XCTAssertEqual(shutdown(socketFD, SHUT_WR), 0)
        await fulfillment(of: [disconnected], timeout: 2.0)
    }

    func testPermissionDisconnectAfterExtraByteAndHalfCloseCancelsPendingRequest() async throws {
        let server = HTTPServer()
        defer { server.stop() }

        let requestHandled = expectation(description: "permission handler invoked")
        let disconnected = expectation(description: "client disconnect observed after extra byte")

        server.setPermissionRequestHandler { request in
            request.setDisconnectHandler {
                disconnected.fulfill()
            }
            requestHandled.fulfill()
        }

        let startedPort = await server.start()
        let port = try XCTUnwrap(startedPort)
        let socketFD = try makeSocket(port: port)
        defer { close(socketFD) }

        let body = Data("{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sleep 30\"},\"session_id\":\"test-disconnect-extra\"}".utf8)
        let headerLines = [
            "POST /permission HTTP/1.1",
            "Host: 127.0.0.1",
            "Content-Type: application/json",
            "Content-Length: \(body.count)",
            "",
            "",
        ]

        var request = Data(headerLines.joined(separator: "\r\n").utf8)
        request.append(body)
        request.append(Data("X".utf8))

        try writeAll(request, to: socketFD)
        await fulfillment(of: [requestHandled], timeout: 1.0)

        XCTAssertEqual(shutdown(socketFD, SHUT_WR), 0)
        await fulfillment(of: [disconnected], timeout: 2.0)
    }

    private func makeSocket(port: Int) throws -> Int32 {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw posixError()
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)

        let conversionResult = "127.0.0.1".withCString { source in
            inet_pton(AF_INET, source, &address.sin_addr)
        }
        guard conversionResult == 1 else {
            close(socketFD)
            throw posixError()
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            let error = posixError()
            close(socketFD)
            throw error
        }

        return socketFD
    }

    private func writeAll(_ data: Data, to socketFD: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }

            var sent = 0
            while sent < data.count {
                let written = Darwin.write(
                    socketFD,
                    baseAddress.advanced(by: sent),
                    data.count - sent
                )
                guard written >= 0 else {
                    throw posixError()
                }
                sent += written
            }
        }
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

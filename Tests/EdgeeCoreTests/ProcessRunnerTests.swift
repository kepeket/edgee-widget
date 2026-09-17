import Foundation
import XCTest
@testable import EdgeeCore

final class ProcessRunnerTests: XCTestCase {
    func testSuccessfulCommandReturnsOutput() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["ready"], timeout: 2
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "ready\n")
    }

    func testRepeatedCommandsFinishAfterAsyncSuspension() async throws {
        let completed = expectation(description: "All completed children return")
        let task = Task {
            defer { completed.fulfill() }
            do {
                for _ in 0..<20 {
                    let result = try await ProcessRunner.run(
                        executable: URL(fileURLWithPath: "/bin/sh"),
                        arguments: ["-c", "sleep 0.02; printf ready; exit 7"],
                        timeout: 2
                    )
                    XCTAssertEqual(result.status, 7)
                    XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "ready")
                }
            } catch {
                XCTFail("Command failed: \(error)")
            }
        }
        await fulfillment(of: [completed], timeout: 5)
        task.cancel()
    }

    func testTimeoutTerminatesChildAndReturns() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"], timeout: 0.1
        )
        XCTAssertEqual(result.status, 124)
    }

    func testCancellationTerminatesChildAndReturns() async throws {
        let task = Task {
            try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"], timeout: 20
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled command should throw")
        } catch is CancellationError {
            // Expected: cancellation must finish without waiting for the child.
        }
    }
}

import XCTest

/// H35: output above the 64 KB pipe buffer used to block the writer forever (the reader only ran after the CLI returned).
final class CLIStdoutCaptureTests: XCTestCase {
    private struct Boom: Error {}

    /// Runs `work` off the test thread so a hang fails after 10 s instead of freezing the suite.
    private func withWatchdog<T>(_ work: @escaping () -> T, file: StaticString = #filePath, line: UInt = #line) -> T? {
        let done = DispatchSemaphore(value: 0)
        var result: T?
        Thread.detachNewThread { result = work(); done.signal() }
        guard done.wait(timeout: .now() + 10) == .success else {
            XCTFail("stdout capture hung: output larger than the pipe buffer", file: file, line: line)
            return nil
        }
        return result
    }

    func testCaptureReturnsOutputLargerThanThePipeBuffer() throws {
        let size = 300_000
        let result = withWatchdog {
            CLIStdoutCapture.capture {
                FileHandle.standardOutput.write(Data(repeating: 0x61, count: size))
            }
        }
        let captured = try XCTUnwrap(result)
        XCTAssertNil(captured.error)
        XCTAssertEqual(captured.out.count, size)
    }

    func testCaptureRestoresStdoutAndRethrowsOnError() throws {
        var before = stat(), after = stat()
        fstat(STDOUT_FILENO, &before)
        let result = withWatchdog {
            CLIStdoutCapture.capture { FileHandle.standardOutput.write(Data("x".utf8)); throw Boom() }
        }
        fstat(STDOUT_FILENO, &after)
        let captured = try XCTUnwrap(result)
        XCTAssertTrue(captured.error is Boom)
        XCTAssertEqual(captured.out, Data("x".utf8))
        XCTAssertEqual(before.st_ino, after.st_ino)
        XCTAssertEqual(before.st_dev, after.st_dev)
    }
}

#!/usr/bin/env bash
set -euo pipefail

emulator_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$emulator_root" <<'PY'
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
probe = subprocess.run(
    ["swiftc", "-typecheck", "-"], input="import XCTest\n",
    text=True, capture_output=True,
)
if probe.returncode == 0:
    subprocess.run(["swift", "test", "--filter", "PadEmulatorTests"], cwd=root, check=True)
    sys.exit(0)

print("XCTest is unavailable; running PadEmulatorTests with a standalone assertion harness.", flush=True)
print("These checks use only the emulator, with no physical device access.", flush=True)

source = (root / "Tests/WLKitTests/PadEmulatorTests.swift").read_text()
source = source.replace("import XCTest\n@testable import WLKit", "import Foundation")
tests = re.findall(r"func (test\w+)\(\) (async )?throws", source)
declared = re.findall(r"func (test\w+)\(", source)
if not tests or [name for name, _ in tests] != declared:
    sys.exit("Unsupported test signature: update this harness or run swift test with Xcode installed.")

# Only the XCTest APIs used by these original test bodies are supported.
# Unsupported assertions or expectation APIs fail compilation.
support = r'''
final class XCTestExpectation {
    let description: String
    var expectedFulfillmentCount = 1
    var isInverted = false
    private let lock = NSLock()
    private var fulfillmentCount = 0

    init(_ description: String) { self.description = description }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return fulfillmentCount
    }

    func fulfill() {
        lock.lock()
        defer { lock.unlock() }
        fulfillmentCount += 1
    }
}

class XCTestCase {
    func expectation(description: String) -> XCTestExpectation { XCTestExpectation(description) }

    func fulfillment(of expectations: [XCTestExpectation], timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for expectation in expectations where expectation.isInverted && expectation.count > 0 {
                fatalError("Unexpected fulfillment: \(expectation.description)")
            }
            if !expectations.contains(where: { $0.isInverted }),
               expectations.allSatisfy({ $0.count >= $0.expectedFulfillmentCount }) { return }
            try! await Task.sleep(nanoseconds: 1_000_000)
        }
        for expectation in expectations {
            let fulfilled = expectation.isInverted
                ? expectation.count == 0
                : expectation.count >= expectation.expectedFulfillmentCount
            guard fulfilled else { fatalError("Expectation failed: \(expectation.description)") }
        }
    }
}

func XCTFail(_ message: String = "Failure", file: StaticString = #file, line: UInt = #line) {
    fatalError(message, file: file, line: line)
}

func XCTAssertEqual<T: Equatable>(
    _ actual: @autoclosure () throws -> T,
    _ expected: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file, line: UInt = #line
) {
    do {
        let a = try actual(), b = try expected()
        guard a == b else { XCTFail("Expected \(b), got \(a). \(message())", file: file, line: line); return }
    } catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}

func XCTAssertTrue(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file, line: UInt = #line
) {
    do {
        if try !expression() { XCTFail("Expected true. \(message())", file: file, line: line) }
    } catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}

func XCTAssertFalse(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file, line: UInt = #line
) {
    do {
        if try expression() { XCTFail("Expected false. \(message())", file: file, line: line) }
    } catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}

func XCTAssertNil<T>(
    _ expression: @autoclosure () throws -> T?,
    file: StaticString = #file, line: UInt = #line
) {
    do {
        if try expression() != nil { XCTFail("Expected nil", file: file, line: line) }
    } catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}

func XCTAssertNotNil<T>(
    _ expression: @autoclosure () throws -> T?,
    file: StaticString = #file, line: UInt = #line
) {
    do {
        if try expression() == nil { XCTFail("Expected a value", file: file, line: line) }
    } catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
'''

runner = "\n@main struct Runner { @MainActor static func main() async throws {\nlet tests = PadEmulatorTests()\n"
for name, asynchronous in tests:
    runner += f'try {"await " if asynchronous else ""}tests.{name}()\nprint("PASS {name}")\n'
runner += f'print("Passed {len(tests)} emulator regression checks.")\n}}}}\n'

with tempfile.TemporaryDirectory(prefix="t3-emulator-verification-") as directory:
    temporary = Path(directory)
    harness = temporary / "PadEmulatorHarness.swift"
    harness.write_text(source + support + runner)
    sources = ["OAIProtocol", "KeymapManager", "LayerMapping", "PadEmulator", "WLDevice", "WLDevice+Async"]
    executable = temporary / "verify"
    subprocess.run([
        "swiftc", "-swift-version", "5", "-parse-as-library", "-o", str(executable),
        *[str(root / f"Sources/WLKit/{name}.swift") for name in sources], str(harness),
    ], check=True)
    subprocess.run([str(executable)], check=True)
PY

#!/usr/bin/env bash
set -euo pipefail

mapping_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$mapping_root" <<'PY'
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
probe = subprocess.run(
    ["swiftc", "-typecheck", "-"], input="import XCTest\n",
    text=True, capture_output=True,
)
if probe.returncode == 0:
    subprocess.run(["swift", "test", "--filter", "LayerMappingTests"], cwd=root, check=True)
    sys.exit(0)

print("XCTest is unavailable; running LayerMappingTests with a standalone assertion harness.", flush=True)
print("These checks use only the fixture and emulator, with no physical device access.", flush=True)

source = (root / "Tests/WLKitTests/LayerMappingTests.swift").read_text()
source = source.replace("import XCTest\n@testable import WLKit", "import Foundation")
tests = re.findall(r"func (test\w+)\(\) (async )?throws", source)
declared = re.findall(r"func (test\w+)\(", source)
if not tests or [name for name, _ in tests] != declared:
    sys.exit("Unsupported test signature: update this harness or run swift test with Xcode installed.")

# This adapter supports only the assertions used by LayerMappingTests. It is
# intentionally not a general XCTest runner: unsupported XCTest APIs fail compilation.
support = r'''
class XCTestCase {}

func XCTAssertEqual<T: Equatable>(
    _ actual: @autoclosure () throws -> T,
    _ expected: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file, line: UInt = #line
) {
    do {
        let a = try actual(), b = try expected()
        guard a == b else { fatalError("Expected \(b), got \(a). \(message())", file: file, line: line) }
    } catch { fatalError("Unexpected error: \(error)", file: file, line: line) }
}

func XCTAssertTrue(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file, line: UInt = #line
) {
    do {
        guard try expression() else { fatalError("Expected true. \(message())", file: file, line: line) }
    } catch { fatalError("Unexpected error: \(error)", file: file, line: line) }
}

func XCTAssertFalse(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file, line: UInt = #line
) {
    do {
        guard try !expression() else { fatalError("Expected false. \(message())", file: file, line: line) }
    } catch { fatalError("Unexpected error: \(error)", file: file, line: line) }
}

func XCTAssertThrowsError<T>(
    _ expression: @autoclosure () throws -> T,
    file: StaticString = #file, line: UInt = #line
) {
    do { _ = try expression() } catch { return }
    fatalError("Expected an error", file: file, line: line)
}

func XCTUnwrap<T>(_ expression: @autoclosure () throws -> T?) throws -> T {
    guard let value = try expression() else { fatalError("Expected a value") }
    return value
}
'''

runner = "\n@main struct Runner { static func main() async throws {\nlet tests = LayerMappingTests()\n"
for name, asynchronous in tests:
    runner += f'try {"await " if asynchronous else ""}tests.{name}()\nprint("PASS {name}")\n'
runner += f'print("Passed {len(tests)} mapping regression checks.")\n}}}}\n'

with tempfile.TemporaryDirectory(prefix="t3-mapping-verification-") as directory:
    temporary = Path(directory)
    harness = temporary / "LayerMappingHarness.swift"
    harness.write_text(source + support + runner)
    (temporary / "Fixtures").mkdir()
    shutil.copy(root / "Tests/WLKitTests/Fixtures/stock-keymap.json", temporary / "Fixtures")
    sources = ["OAIProtocol", "KeymapManager", "LayerMapping", "PadEmulator", "WLDevice", "WLDevice+Async"]
    executable = temporary / "verify"
    subprocess.run([
        "swiftc", "-swift-version", "5", "-parse-as-library", "-o", str(executable),
        *[str(root / f"Sources/WLKit/{name}.swift") for name in sources], str(harness),
    ], check=True)
    subprocess.run([str(executable)], check=True)
PY

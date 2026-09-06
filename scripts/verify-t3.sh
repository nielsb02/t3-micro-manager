#!/bin/bash
# Run the provider's existing test bodies with Foundation when XCTest is unavailable.
set -euo pipefail

t3_repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$t3_repo"
swift build --target WLKit
t3_temp=$(mktemp -d "${TMPDIR:-/tmp}/verify-t3.XXXXXX")
trap 'rm -rf "$t3_temp"' EXIT

python3 - "$t3_repo" "$t3_temp" <<'PY'
from pathlib import Path
import re
import sys

repo, output = map(Path, sys.argv[1:])
tests = (repo / 'Tests/WLKitTests/T3ClientTests.swift').read_text()
tests = tests.replace('import XCTest', '')
methods = re.findall(r'func (test\w+)\(\) (async )?throws', tests)
assert methods, 'No provider tests found'
shim = r'''
class XCTestCase {}
func XCTFail(_ message: String = "Failure", file: StaticString = #file, line: UInt = #line) {
    fatalError(message, file: file, line: line)
}
func XCTAssertEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { let a = try actual(); let e = try expected(); if a != e { XCTFail("Expected \(e), got \(a)", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertTrue(_ expression: @autoclosure () throws -> Bool, file: StaticString = #file, line: UInt = #line) {
    do { if try !expression() { XCTFail("Expected true", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertFalse(_ expression: @autoclosure () throws -> Bool, file: StaticString = #file, line: UInt = #line) {
    do { if try expression() { XCTFail("Expected false", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertNil<T>(_ expression: @autoclosure () throws -> T?, file: StaticString = #file, line: UInt = #line) {
    do { if try expression() != nil { XCTFail("Expected nil", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { _ = try expression(); XCTFail("Expected error", file: file, line: line) } catch { }
}
'''
calls = '\n'.join(f'        try {"await " if asynchronous else ""}tests.{name}()' for name, asynchronous in methods)
runner = f'''
@main struct ProviderChecks {{
    @MainActor static func main() async throws {{
        let tests = T3ClientTests()
{calls}
        print("PASS: {len(methods)} T3 provider checks (original test bodies, Foundation harness)")
    }}
}}
'''
(output / 'Checks.swift').write_text(tests + shim + runner)
PY

swiftc -parse-as-library -I .build/debug/Modules "$t3_temp/Checks.swift" \
    .build/debug/WLKit.build/*.o -o "$t3_temp/check"
"$t3_temp/check"

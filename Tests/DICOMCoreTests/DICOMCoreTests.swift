import XCTest
@testable import DICOMCore
final class DICOMCoreTests: XCTestCase { func testDictionary() { XCTAssertEqual(DataDictionary.name(for: .patientName), "Patient Name") } }

import AVFoundation
import XCTest
import MyPlugInCatalog
import MyPlugInCore

final class MyPlugInCatalogTests: XCTestCase {
    private let manufacturer = MyFXFourCC("CtlT")

    func testComponentsAndNamesAreUnique() {
        let subtypes = MyPlugInCatalog.plugIns.map { $0.componentDescription.componentSubType }
        XCTAssertEqual(Set(subtypes).count, subtypes.count)
        let names = MyPlugInCatalog.plugIns.map { $0.displayName }
        XCTAssertEqual(Set(names).count, names.count)
    }

    /// Every effect registers, is found by a scan, instantiates and renders
    /// its parameters with unique identifiers.
    func testEveryEffectRegistersAndInstantiates() throws {
        MyPlugInCatalog.registerAll(manufacturer: manufacturer, vendorName: "Catalog Test")
        for plugIn in MyPlugInCatalog.plugIns {
            let description = MyPlugInCatalog.componentDescription(of: plugIn, manufacturer: manufacturer)
            var query = description
            let component = try XCTUnwrap(AudioComponentFindNext(nil, &query), "\(plugIn) not found")
            var name: Unmanaged<CFString>?
            AudioComponentCopyName(component, &name)
            XCTAssertEqual(name?.takeRetainedValue() as String?, "Catalog Test: \(plugIn.displayName)")

            let instantiated = expectation(description: "\(plugIn)")
            var unit: AVAudioUnit?
            AVAudioUnit.instantiate(with: description, options: []) { audioUnit, _ in
                unit = audioUnit
                instantiated.fulfill()
            }
            wait(for: [instantiated], timeout: 5)
            let audioUnit = try XCTUnwrap(unit?.auAudioUnit as? MyFXAudioUnit)
            XCTAssertTrue(type(of: audioUnit) == plugIn)
            XCTAssertEqual(unit?.name, plugIn.displayName)
            let identifiers = audioUnit.parameterTree?.allParameters.map(\.identifier) ?? []
            XCTAssertFalse(identifiers.isEmpty)
            XCTAssertEqual(Set(identifiers).count, identifiers.count)
        }
    }
}

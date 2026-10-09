import AVFoundation
import XCTest
@testable import MyChannelStrip
import MyPlugInCore

final class MyChannelStripAudioUnitTests: XCTestCase {
    func testParametersAreUniqueAndComplete() {
        let parameters = ChannelStripParameter.allCases
        XCTAssertEqual(parameters.count, 37)
        XCTAssertEqual(Set(parameters.map(\.identifier)).count, parameters.count)
        XCTAssertFalse(parameters.contains { $0.identifier.isEmpty || $0.displayName.isEmpty })
        XCTAssertTrue(parameters.allSatisfy { $0.rawValue < ChannelStripParameter.addressCount })
        XCTAssertEqual(ChannelStripParameter.band(2, .q), .band3Q)
        XCTAssertEqual(ChannelStripParameter.band4Slope.identifier, "band4_slope")
        XCTAssertEqual(ChannelStripParameter.compOn.defaultValue, 0)
        for parameter in parameters {
            XCTAssertEqual(parameter.clamped(parameter.defaultValue), parameter.defaultValue, "\(parameter)")
        }
    }

    func testDisplayStringsParseBack() {
        let frequency = ChannelStripParameter.band1Frequency
        XCTAssertEqual(frequency.displayString(for: 2_500), "2.50k")
        XCTAssertEqual(frequency.value(fromDisplayString: "2.5k"), 2_500)
        XCTAssertEqual(frequency.value(fromDisplayString: "120"), 120)
        XCTAssertEqual(ChannelStripParameter.band1Type.value(fromDisplayString: "high cut"),
                       Float(ChannelStripFilterType.highCut.rawValue))
        XCTAssertEqual(ChannelStripParameter.order.displayString(for: 1), "COMP > EQ")
        XCTAssertEqual(ChannelStripParameter.compRatio.displayString(for: 2), "2.0:1")
        XCTAssertEqual(ChannelStripParameter.compOn.value(fromDisplayString: "On"), 1)
        XCTAssertEqual(ChannelStripParameter.outputGain.value(fromDisplayString: "+30"), 24)
    }

    func testUnitStateAndEditor() throws {
        let unit = try MyChannelStripAudioUnit(componentDescription: MyChannelStripAudioUnit.componentDescription)
        XCTAssertEqual(unit.parameterTree?.allParameters.map(\.identifier),
                       ChannelStripParameter.allCases.map(\.identifier))
        let threshold = AUParameterAddress(ChannelStripParameter.compThreshold.rawValue)
        unit.parameterTree?.parameter(withAddress: threshold)?.value = -32
        let state = unit.fullState

        let restored = try MyChannelStripAudioUnit(componentDescription: MyChannelStripAudioUnit.componentDescription)
        restored.fullState = state
        XCTAssertEqual(restored.parameterTree?.parameter(withAddress: threshold)?.value, -32)
        XCTAssertEqual(restored.stripKernel.target(.compThreshold), -32)

        XCTAssertEqual(unit.makeEditorViewController().view.frame.size, NSSize(width: 300, height: 464))
        XCTAssertEqual(unit.makeEditorViewController().preferredContentSize, MyChannelStripAudioUnit.editorSize)
    }

    /// The editor shows the host's channel name (contextName) and follows renames.
    func testEditorFollowsTheChannelName() throws {
        let unit = try MyChannelStripAudioUnit(componentDescription: MyChannelStripAudioUnit.componentDescription)
        unit.contextName = "Vocal"
        let controller = unit.makeEditorViewController()
        XCTAssertEqual(controller.model.channelName, "Vocal")
        unit.contextName = "Lead Vocal"
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(controller.model.channelName, "Lead Vocal")
    }
}

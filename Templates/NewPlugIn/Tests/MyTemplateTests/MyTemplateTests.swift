import AVFoundation
import XCTest
@testable import MyTemplate
import MyPlugInCore

final class MyTemplateTests: XCTestCase {
    private func render(_ kernel: TemplateKernel, _ input: [Float]) -> [Float] {
        var output = input
        input.withUnsafeBufferPointer { inPointer in
            output.withUnsafeMutableBufferPointer { outPointer in
                kernel.process(inputLeft: inPointer.baseAddress!, inputRight: inPointer.baseAddress!,
                               outputLeft: outPointer.baseAddress!, outputRight: nil, frameCount: input.count)
            }
        }
        return output
    }

    func testMixZeroPassesDry() {
        let kernel = TemplateKernel()
        kernel.setTarget(.mix, 0)
        kernel.setTarget(.gain, 12)
        kernel.prepare(sampleRate: 48_000, maximumFrames: 512)
        let input: [Float] = (0..<512).map { Float($0 % 9) * 0.05 }
        XCTAssertEqual(render(kernel, input), input)
    }

    func testGainIsApplied() {
        let kernel = TemplateKernel()
        kernel.setTarget(.gain, 20 * log10(2))
        kernel.prepare(sampleRate: 48_000, maximumFrames: 512)
        let output = render(kernel, [Float](repeating: 0.25, count: 512))
        XCTAssertEqual(output[511], 0.5, accuracy: 1e-5)
    }

    func testUnitAndEditor() throws {
        let unit = try MyTemplateAudioUnit(componentDescription: MyTemplateAudioUnit.componentDescription)
        XCTAssertEqual(unit.parameterTree?.allParameters.map(\.identifier), TemplateParameter.allCases.map(\.identifier))
        XCTAssertEqual(unit.makeEditorViewController().view.frame.size, MyFXEditorViewController.preferredSize)
    }
}

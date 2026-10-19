import PulseEightCore
import Testing
@testable import PulseEightControl

@MainActor
@Suite struct HardwareTopicTests {
    let strings = Strings(language: .english)

    @Test func topicsAreListedInTheOrderTheWindowsAppUsesWithMaintenanceAfterTheFrontPanel() {
        #expect(HardwareTopic.allCases.map(\.rawValue) == [
            "system", "features", "health", "diagnostics", "frontPanel", "maintenance", "updates", "inputs", "outputs",
        ])
    }

    @Test func everyTopicHasATitleADescriptionAndAnIcon() {
        for topic in HardwareTopic.allCases {
            #expect(!topic.title(strings).isEmpty, "\(topic)")
            #expect(!topic.description(strings).isEmpty, "\(topic)")
            #expect(!topic.symbol.isEmpty, "\(topic)")
        }
        #expect(Set(HardwareTopic.allCases.map(\.symbol)).count == HardwareTopic.allCases.count, "icons are distinct")
    }

    @Test func titlesComeFromTheSharedCatalogSoBothAppsSayTheSame() {
        #expect(HardwareTopic.system.title(strings) == strings.text(.hardwareSystem))
        #expect(HardwareTopic.updates.title(strings) == strings.text(.hardwareFirmwareUpdates))
        #expect(HardwareTopic.outputs.description(strings) == strings.text(.hardwareOutputsDescription))
    }

    @Test func theBacklightLabelsAreTheCatalogsOffLowHigh() {
        #expect(BacklightOption.allCases.map { strings.text($0.titleKey) } == ["Off", "Low", "High"])
        #expect(BacklightOption.allCases.map(\.level) == [.off, .low, .high])
    }

    @Test func switchingMatrixReturnsToTheListOfTopics() async throws {
        let h = await Harness.make()
        h.model.beginEditingMatrix(nil)
        h.model.matrixDraft.host = "10.0.0.20"
        h.model.saveMatrixDraft()
        #expect(await waitUntil { h.model.matrices.count == 2 })
        let other = try #require(h.model.matrices.last).id

        h.model.hardwareTopic = .health
        h.model.selectMatrix(id: other)
        #expect(h.model.hardwareTopic == nil, "another matrix may not have that topic")
    }
}

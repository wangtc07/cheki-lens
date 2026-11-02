import XCTest
import SwiftData
@testable import ChekiLens

@MainActor
final class ModelContainerProviderTests: XCTestCase {

    func test_makeConfiguration_localVsCloudKit() {
        let localConfig = ModelContainerProvider.makeConfiguration(enableCloudKit: false)
        XCTAssertTrue(String(describing: localConfig.cloudKitDatabase).contains("none"), "未啟用時應為 none")

        let cloudConfig = ModelContainerProvider.makeConfiguration(enableCloudKit: true)
        XCTAssertTrue(String(describing: cloudConfig.cloudKitDatabase).contains("automatic"), "啟用時應為 automatic")
    }

    func test_migrateData_betweenContainers() throws {
        // Arrange
        let sourceContainer = try ModelContainerProvider.preview(withSampleData: false)
        let targetContainer = try ModelContainerProvider.preview(withSampleData: false)

        let group = IdolGroup(name: "乃木坂46")
        let member = IdolMember(stageName: "山下美月", group: group)
        let item = ChekiItem(idolMember: member)
        let memo = ChekiMemo(eventName: "卒コン", chekiItem: item)

        sourceContainer.mainContext.insert(group)
        sourceContainer.mainContext.insert(member)
        sourceContainer.mainContext.insert(item)
        sourceContainer.mainContext.insert(memo)
        try sourceContainer.mainContext.save()

        // Act
        let result = try ModelContainerProvider.migrateData(from: sourceContainer, to: targetContainer)

        // Assert
        XCTAssertEqual(result.groups, 1)
        XCTAssertEqual(result.members, 1)
        XCTAssertEqual(result.chekis, 1)
        XCTAssertEqual(result.memos, 1)

        let targetItems = try targetContainer.mainContext.fetch(FetchDescriptor<ChekiItem>())
        XCTAssertEqual(targetItems.count, 1)
        XCTAssertEqual(targetItems.first?.id, item.id)

        // Repeat migration should be idempotent (0 newly migrated)
        let repeatResult = try ModelContainerProvider.migrateData(from: sourceContainer, to: targetContainer)
        XCTAssertEqual(repeatResult.groups, 0)
        XCTAssertEqual(repeatResult.members, 0)
        XCTAssertEqual(repeatResult.chekis, 0)
        XCTAssertEqual(repeatResult.memos, 0)
    }
}

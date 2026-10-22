import XCTest
import Photos
@testable import ChekiLens

final class PhotoCloudIdentifierMapperTests: XCTestCase {

    func test_mockMapper_bidirectionalLookup() {
        let mapper = MockPhotoCloudIdentifierMapper()
        let localID = "E9C40523-EC12-4B6A-8A91-000000000001/L0/001"
        let cloudID = "cloud-id-test-001"

        mapper.register(localIdentifier: localID, cloudIdentifier: cloudID)

        XCTAssertEqual(mapper.cloudIdentifier(forLocalIdentifier: localID), cloudID)
        XCTAssertEqual(mapper.localIdentifier(forCloudIdentifier: cloudID), localID)
        XCTAssertTrue(mapper.assetExists(forLocalIdentifier: localID))
    }

    func test_mockMapper_batchLookup() {
        let initialMappings = [
            "local-1": "cloud-1",
            "local-2": "cloud-2",
            "local-3": "cloud-3"
        ]
        let mapper = MockPhotoCloudIdentifierMapper(mappings: initialMappings)

        let cloudBatch = mapper.batchCloudIdentifiers(forLocalIdentifiers: ["local-1", "local-3", "local-99"])
        XCTAssertEqual(cloudBatch.count, 2)
        XCTAssertEqual(cloudBatch["local-1"], "cloud-1")
        XCTAssertEqual(cloudBatch["local-3"], "cloud-3")
        XCTAssertNil(cloudBatch["local-99"])

        let localBatch = mapper.batchLocalIdentifiers(forCloudIdentifiers: ["cloud-2", "cloud-3", "cloud-unknown"])
        XCTAssertEqual(localBatch.count, 2)
        XCTAssertEqual(localBatch["cloud-2"], "local-2")
        XCTAssertEqual(localBatch["cloud-3"], "local-3")
        XCTAssertNil(localBatch["cloud-unknown"])
    }

    func test_mockMapper_notFoundCases() {
        let mapper = MockPhotoCloudIdentifierMapper()

        XCTAssertNil(mapper.cloudIdentifier(forLocalIdentifier: "non-existent-local"))
        XCTAssertNil(mapper.localIdentifier(forCloudIdentifier: "non-existent-cloud"))
        XCTAssertFalse(mapper.assetExists(forLocalIdentifier: "non-existent-local"))
    }

    func test_realMapper_emptyInputs_returnsEmpty() {
        let realMapper = PhotoCloudIdentifierMapper.shared

        XCTAssertEqual(realMapper.batchCloudIdentifiers(forLocalIdentifiers: []), [:])
        XCTAssertEqual(realMapper.batchLocalIdentifiers(forCloudIdentifiers: []), [:])
        XCTAssertNil(realMapper.cloudIdentifier(forLocalIdentifier: ""))
        XCTAssertNil(realMapper.localIdentifier(forCloudIdentifier: ""))
    }
}

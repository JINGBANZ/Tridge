import CoreData
import XCTest
@testable import Tridge

/// The model has to satisfy CloudKit's rules *before* the development schema is
/// initialized, because several of them — field encryption above all — cannot be
/// changed casually after a field ships. These assertions are the offline
/// equivalent of `initializeCloudKitSchema`, which needs a real account.
final class CoreDataModelTests: XCTestCase {
    private var model: NSManagedObjectModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        model = try XCTUnwrap(TridgeModel.managedObjectModel, "the compiled model is missing")
    }

    private func entity(_ name: String) throws -> NSEntityDescription {
        try XCTUnwrap(model.entitiesByName[name], "missing entity \(name)")
    }

    func testTheModelContainsExactlyTheContractEntities() {
        XCTAssertEqual(Set(model.entitiesByName.keys), [
            "HouseholdRecord", "FridgeItemRecord", "StockChangeRecord",
            "ItemMergeRecord", "HouseholdClearRecord",
        ])
    }

    // MARK: - CloudKit compatibility

    func testEveryAttributeIsOptionalOrCarriesADefaultValue() {
        for entity in model.entities {
            for (name, attribute) in entity.attributesByName {
                XCTAssertTrue(attribute.isOptional || attribute.defaultValue != nil,
                              "\(entity.name!).\(name) is neither optional nor defaulted")
            }
        }
    }

    func testNoAttributeIsTransformable() {
        for entity in model.entities {
            for (name, attribute) in entity.attributesByName {
                XCTAssertNotEqual(attribute.attributeType, .transformableAttributeType,
                                  "\(entity.name!).\(name) is transformable")
            }
        }
    }

    func testEveryRelationshipIsOptionalUnorderedAndHasAnInverse() {
        for entity in model.entities {
            for (name, relationship) in entity.relationshipsByName {
                let label = "\(entity.name!).\(name)"
                XCTAssertTrue(relationship.isOptional, "\(label) is required")
                XCTAssertFalse(relationship.isOrdered, "\(label) is ordered")
                XCTAssertNotNil(relationship.inverseRelationship, "\(label) has no inverse")
            }
        }
    }

    func testNoEntityUsesUniquenessConstraintsOrDenyDeleteRules() {
        for entity in model.entities {
            XCTAssertTrue(entity.uniquenessConstraints.isEmpty,
                          "\(entity.name!) declares a uniqueness constraint")
            for (name, relationship) in entity.relationshipsByName {
                XCTAssertNotEqual(relationship.deleteRule, .denyDeleteRule,
                                  "\(entity.name!).\(name) denies deletion")
            }
        }
    }

    // MARK: - Encryption

    func testExactlyTheUserContentAttributesAllowCloudEncryption() throws {
        // Ids, epoch revisions, and bookkeeping timestamps stay readable so
        // diagnostics and merge claims keep working; everything a person typed
        // or bought is encrypted.
        let expected: [String: Set<String>] = [
            "HouseholdRecord": ["name"],
            "FridgeItemRecord": ["name", "normalizedName", "artKey", "storageRaw",
                                 "purchaseDay", "expiryDay", "expirySourceRaw"],
            "StockChangeRecord": ["delta", "reasonRaw", "occurredAt"],
            "ItemMergeRecord": [],
            "HouseholdClearRecord": ["occurredAt"],
        ]

        for (entityName, encrypted) in expected {
            let entity = try self.entity(entityName)
            let actual = Set(entity.attributesByName.filter { $0.value.allowsCloudEncryption }.keys)
            XCTAssertEqual(actual, encrypted, "\(entityName) encrypts the wrong attributes")
        }
    }

    // MARK: - Shape

    func testHouseholdCascadesToItsChildrenAndChildrenNullifyBack() throws {
        let household = try entity("HouseholdRecord")
        for name in ["items", "itemMerges", "clearEvents"] {
            let relationship = try XCTUnwrap(household.relationshipsByName[name])
            XCTAssertTrue(relationship.isToMany)
            XCTAssertEqual(relationship.deleteRule, .cascadeDeleteRule)
            XCTAssertEqual(relationship.inverseRelationship?.deleteRule, .nullifyDeleteRule)
            XCTAssertEqual(relationship.inverseRelationship?.isToMany, false)
        }

        let item = try entity("FridgeItemRecord")
        let stockChanges = try XCTUnwrap(item.relationshipsByName["stockChanges"])
        XCTAssertEqual(stockChanges.deleteRule, .cascadeDeleteRule)
        XCTAssertEqual(stockChanges.inverseRelationship?.deleteRule, .nullifyDeleteRule)
    }

    func testTheLocalFetchIndexesTheRepositoryQueriesOnExist() throws {
        let indexed: [String: [String: [String]]] = [
            "FridgeItemRecord": ["byNormalizedName": ["normalizedName"]],
            "ItemMergeRecord": ["byLeftItemID": ["leftItemID"], "byRightItemID": ["rightItemID"]],
            "HouseholdClearRecord": ["byRevision": ["revision"]],
        ]

        for (entityName, expected) in indexed {
            let entity = try self.entity(entityName)
            let indexes = Dictionary(uniqueKeysWithValues: entity.indexes.map {
                ($0.name, $0.elements.compactMap { $0.property?.name })
            })
            XCTAssertEqual(indexes, expected, "\(entityName) indexes drifted")
        }
    }

    func testInventoryDaysArePersistedAsDayOrdinalsRatherThanInstants() throws {
        // Purchase and Expiry Day are civil days (ADR 0003); persisting them as
        // dates would reintroduce the time zone the ordinal removes.
        let item = try entity("FridgeItemRecord")
        for name in ["purchaseDay", "expiryDay"] {
            XCTAssertEqual(item.attributesByName[name]?.attributeType, .integer32AttributeType)
        }
    }

    func testNothingReceiptShapedOrDerivedIsPersisted() throws {
        // Receipt text never reaches the stores; quantity, status, deletion,
        // urgency, and Food Category all derive from events, the expiry day, and
        // the art key.
        let item = try entity("FridgeItemRecord")
        for absent in ["receiptText", "quantity", "status", "consumedDate", "isDeleted",
                       "urgency", "foodCategory"] {
            XCTAssertNil(item.attributesByName[absent], "\(absent) must not be persisted")
        }
    }
}

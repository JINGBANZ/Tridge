import Foundation

/// One fixture: a receipt image plus its expected inventory. A fixture is any
/// directory under Fixtures/ (recursively, so gitignored private/ works too)
/// holding an `expected.json` and one image file.
struct ReceiptFixture {
    let name: String
    let imageData: Data
    let expectation: ReceiptExpectation

    static let imageExtensions = ["jpg", "jpeg", "png"]

    static func loadAll() throws -> [ReceiptFixture] {
        guard let root = Bundle.module.resourceURL?.appendingPathComponent("Fixtures"),
              FileManager.default.fileExists(atPath: root.path) else { return [] }

        var fixtures: [ReceiptFixture] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.lastPathComponent == "expected.json" else { continue }
            let directory = url.deletingLastPathComponent()
            let contents = try FileManager.default.contentsOfDirectory(at: directory,
                                                                       includingPropertiesForKeys: nil)
            guard let image = contents.first(where: {
                imageExtensions.contains($0.pathExtension.lowercased())
            }) else {
                throw FixtureError.noImage(directory.lastPathComponent)
            }
            fixtures.append(ReceiptFixture(
                name: directory.lastPathComponent,
                imageData: try Data(contentsOf: image),
                expectation: try JSONDecoder().decode(ReceiptExpectation.self,
                                                      from: Data(contentsOf: url))))
        }
        return fixtures.sorted { $0.name < $1.name }
    }

    enum FixtureError: Error, CustomStringConvertible {
        case noImage(String)

        var description: String {
            switch self {
            case .noImage(let dir):
                "fixture \"\(dir)\" has expected.json but no \(ReceiptFixture.imageExtensions) image"
            }
        }
    }
}

import Foundation

/// One fixture: a receipt image plus its expected inventory. A fixture is any
/// directory under Fixtures/ (recursively, so gitignored private/ works too)
/// holding an `expected.json` and an image — either a file in the directory or
/// an `"image"` path in the json pointing elsewhere in the repo, so images
/// shared with the app bundle (the sample receipt) aren't duplicated.
///
/// Fixtures load straight from the source tree (like `.env`), not from a
/// bundled resource copy.
struct ReceiptFixture {
    let name: String
    let imageData: Data
    let expectation: ReceiptExpectation

    static let imageExtensions = ["jpg", "jpeg", "png"]

    /// Tests/ReceiptScanSmokeTests/Fixtures next to this file.
    static var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    static func loadAll() throws -> [ReceiptFixture] {
        guard FileManager.default.fileExists(atPath: fixturesRoot.path) else { return [] }

        var fixtures: [ReceiptFixture] = []
        let enumerator = FileManager.default.enumerator(at: fixturesRoot,
                                                        includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.lastPathComponent == "expected.json" else { continue }
            let directory = url.deletingLastPathComponent()
            let expectation = try JSONDecoder().decode(ReceiptExpectation.self,
                                                       from: Data(contentsOf: url))
            guard let image = try imageURL(for: expectation, in: directory) else {
                throw FixtureError.noImage(directory.lastPathComponent)
            }
            fixtures.append(ReceiptFixture(
                name: directory.lastPathComponent,
                imageData: try Data(contentsOf: image),
                expectation: expectation))
        }
        return fixtures.sorted { $0.name < $1.name }
    }

    private static func imageURL(for expectation: ReceiptExpectation,
                                 in directory: URL) throws -> URL? {
        if let path = expectation.image {
            let url = directory.appendingPathComponent(path).standardizedFileURL
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let contents = try FileManager.default.contentsOfDirectory(at: directory,
                                                                   includingPropertiesForKeys: nil)
        return contents.first { imageExtensions.contains($0.pathExtension.lowercased()) }
    }

    enum FixtureError: Error, CustomStringConvertible {
        case noImage(String)

        var description: String {
            switch self {
            case .noImage(let dir):
                "fixture \"\(dir)\" resolves to no receipt image — add a \(ReceiptFixture.imageExtensions) file or fix its \"image\" path"
            }
        }
    }
}

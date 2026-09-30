import Foundation
import XCTest

final class FixtureToken {}

enum Fixture {
    static func data(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let bundle = Bundle(for: FixtureToken.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"),
                                "Missing fixture \(name).json", file: file, line: line)
        return try Data(contentsOf: url)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: data(name))
    }
}

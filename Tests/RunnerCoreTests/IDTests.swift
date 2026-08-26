import Foundation
import RunnerCore
import Testing

@Suite struct IDTests {
  @Test func roundTripsThroughJSONAsPlainString() throws {
    let id = InstanceID(rawValue: "abc")
    let data = try JSONEncoder().encode(id)
    #expect(String(data: data, encoding: .utf8) == "\"abc\"")
    #expect(try JSONDecoder().decode(InstanceID.self, from: data) == id)
  }

  @Test func generateProducesLowercaseUUID() {
    let id = RunnerSessionID.generate()
    #expect(id.rawValue == id.rawValue.lowercased())
    #expect(UUID(uuidString: id.rawValue) != nil)
  }
}

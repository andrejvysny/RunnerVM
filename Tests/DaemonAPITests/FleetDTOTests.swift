import Foundation
import Testing

@testable import DaemonAPI

/// The field names `GuestAgent/internal/fleet/client.go` sends and decodes.
@Suite struct FleetDTOTests {
  private func keys<T: Encodable>(_ value: T) throws -> Set<String> {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    return Set((object as? [String: Any] ?? [:]).keys)
  }

  @Test func wireFieldNamesMatchTheGoClient() throws {
    #expect(try keys(FleetInfoResponse(profile: "p", guestOS: "linux", arch: "arm64", sshUser: "runner", maxInstances: 1))
      == ["profile", "guestOS", "arch", "sshUser", "maxInstances"])
    #expect(try keys(FleetCreateRequest(profile: "p", leaseMs: 1)) == ["profile", "leaseMs"])
    #expect(try keys(FleetCreateResponse(id: "i", leaseUntil: "t")) == ["id", "leaseUntil"])
    #expect(try keys(FleetInstanceDTO(id: "i", state: "running", leaseUntil: "t"))
      == ["id", "state", "leaseUntil"])
    #expect(try keys(FleetInstanceDTO(id: "i", state: "running")) == ["id", "state"])
    #expect(try keys(FleetDeleteResponse(id: "i", accepted: true)) == ["id", "accepted"])
    #expect(try keys(FleetRenewRequest(ids: ["i"], leaseMs: 1)) == ["ids", "leaseMs"])
    #expect(try keys(FleetRenewResponse(renewed: [])) == ["renewed"])
    #expect(try keys(FleetConnectRequest(id: "i", publicKey: "k")) == ["id", "publicKey"])
    #expect(try keys(FleetConnectResponse(id: "i", address: "a", port: 22, user: "u", guestOS: "linux", arch: "arm64"))
      == ["id", "address", "port", "user", "guestOS", "arch"])
  }

  @Test func catalogueClassifiesTheFleetMethods() {
    for method in [DaemonMethod.fleetInfo, .fleetList, .fleetCreate, .fleetDelete, .fleetRenew, .fleetConnect] {
      #expect(method.isImplemented)
    }
    #expect(DaemonMethod.fleetInfo.methodClass == .readOnly)
    #expect(DaemonMethod.fleetList.methodClass == .readOnly)
    #expect(DaemonMethod.fleetCreate.methodClass == .singleShot)
    #expect(DaemonMethod.fleetDelete.methodClass == .idempotentMutation)
  }
}

import XCTest
@testable import MowerBarCore

final class ProtocolTests: XCTestCase {
    func testMotionEnvelopeUsesRobotTimeZoneAndNoConfigurationFields() throws {
        let date = ISO8601DateFormatter().date(from: "2026-10-11T10:00:00Z")!
        for command in MowerCommand.allCases {
            let data = try CommandEnvelope.data(command: command, serial: "TEST-ONLY", protocolVersion: 0,
                capabilities: ["safe_go_home"], date: date, id: 1024, timeZone: TimeZone(identifier: "Europe/Paris")!)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(json.keys), ["cmd", "sn", "dt", "tm", "id"])
            XCTAssertEqual(json["cmd"] as? Int, command.rawValue)
            XCTAssertEqual(json["tm"] as? String, "12:00:00")
            XCTAssertEqual(json["dt"] as? String, "11/10/2026")
        }
    }
    func testUnsupportedProtocolAndUnsupportedHomeCannotProduceCommands() {
        XCTAssertThrowsError(try CommandEnvelope.data(command: .start, serial: "TEST", protocolVersion: 1, capabilities: [], id: 1024))
        XCTAssertThrowsError(try CommandEnvelope.data(command: .safeHome, serial: "TEST", protocolVersion: 0, capabilities: [], id: 1024))
        XCTAssertThrowsError(try CommandEnvelope.data(command: .start, serial: "TEST", protocolVersion: 0, capabilities: [], id: 0))
    }
    func testStreamDecoderHandlesEveryByteFragmentAndMultipleFrames() throws {
        let payload = Data(repeating: 65, count: 300)
        let first = MQTTFrame(header: 0x30, body: payload)
        let second = MQTTFrame(header: 0xD0, body: Data())
        let wire = first.encoded + second.encoded
        var decoder = MQTTDecoder(); var frames = [MQTTFrame]()
        for byte in wire { frames += try decoder.append(Data([byte])) }
        XCTAssertEqual(frames, [first, second])
        var joined = MQTTDecoder(); XCTAssertEqual(try joined.append(wire), frames)
    }
    func testMalformedLengthAndTruncatedPublicationAreRejected() {
        var decoder = MQTTDecoder()
        XCTAssertThrowsError(try decoder.append(Data([0x30, 0xFF, 0xFF, 0xFF, 0xFF])))
        XCTAssertThrowsError(try MQTTWire.publication(MQTTFrame(header: 0x32, body: Data([0, 5, 65]))))
        XCTAssertThrowsError(try MQTTWire.publish(topic: "WX/#", payload: Data(), id: 1))
    }
    func testQosOnePublicationExtractsPacketIDAndSkipsMQTT5Properties() throws {
        let payload = Data("{\"cfg\":{},\"dat\":{\"ls\":7}}".utf8)
        let body = try MQTTWire.string("WX/TEST/commandOut") + MQTTWire.u16(73) + Data([2, 1, 0]) + payload
        let value = try MQTTWire.publication(MQTTFrame(header: 0x32, body: body))
        XCTAssertEqual(value.topic, "WX/TEST/commandOut"); XCTAssertEqual(value.id, 73); XCTAssertEqual(value.payload, payload)
    }
    func testCommandsNeverSetRetainOrDuplicateFlags() throws {
        let wire = try MQTTWire.publish(topic: "WX/TEST/commandIn", payload: Data("{}".utf8), id: 1)
        XCTAssertEqual(wire.first, 0x32) // QoS 1, no retained movement, no automatic DUP resend.
    }
    func testJWTAuthorizerEscapesSignatureSeparators() throws {
        let username = try MQTTWire.username(accessToken: "abc.def.a_b-c")
        XCTAssertTrue(username.contains("signature=a%2Fb%2Bc"))
        XCTAssertThrowsError(try MQTTWire.username(accessToken: "not-a-token"))
    }
    func testFreshnessErrorAndConnectionGatesPreventUnsafeStart() {
        let now = Date()
        func policy(state: Int = 34, error: Int? = 0, age: Double = 1, connected: Bool = true, online: Bool = true, pending: Bool = false) -> ControlAvailability {
            let payload: [String: Any] = ["dat": ["ls": state, "le": error as Any]]
            return ControlAvailability(connected: connected, online: online, protocolVersion: 0, pending: pending,
                telemetry: Telemetry.parse(payload, fallbackDate: now.addingTimeInterval(-age)), capabilities: ["safe_go_home"], now: now)
        }
        XCTAssertTrue(policy().start)
        XCTAssertFalse(policy(state: 7).start); XCTAssertTrue(policy(state: 7).pause)
        XCTAssertFalse(policy(error: 1).start); XCTAssertFalse(policy(error: 1).home)
        XCTAssertFalse(policy(age: 301).available); XCTAssertFalse(policy(age: -60).available)
        XCTAssertFalse(policy(connected: false).available); XCTAssertFalse(policy(online: false).available)
        XCTAssertFalse(policy(pending: true).available)
        XCTAssertFalse(policy(error: nil).start)
    }
    func testObservedStateAndErrorMappingsAreNotConfused() {
        let t = Telemetry.parse(["cfg": ["id": 1234], "dat": ["ls": 7, "le": 9, "bt": ["p": 25, "c": 0]]])
        // Without an app bundle, labels resolve to their English keys.
        XCTAssertEqual(t.stateLabel, "Mowing"); XCTAssertEqual(t.errorLabel, "Wheel motor fault")
        XCTAssertEqual(t.correlationID, 1234); XCTAssertEqual(t.battery, 25)
        XCTAssertNotNil(parseCloudDate("2026-10-11 10:28:08"))
    }

    // MARK: Settings and experimental resume

    /// Anonymised `cfg` shaped like a wired mower's: two daily slots, one-time mow present.
    private let sampleConfig = MowerConfig.parse([
        "tq": 0, "rd": 120,
        "sc": ["m": 1, "p": -10, "distm": 0, "ots": ["bc": 0, "wtm": 60],
               "d": [["09:00", 120, 1], ["00:00", 0, 0], ["09:00", 120, 1], ["00:00", 0, 0], ["09:00", 120, 1], ["00:00", 0, 0], ["10:00", 90, 1]],
               "dd": [["00:00", 0, 0], ["00:00", 0, 0], ["15:00", 60, 1], ["00:00", 0, 0], ["00:00", 0, 0], ["00:00", 0, 0], ["00:00", 0, 0]]]])
    private func json(_ setting: MowerSetting) throws -> [String: Any] {
        let data = try CommandEnvelope.setting(setting, config: sampleConfig, serial: "TEST-ONLY", protocolVersion: 0, id: 2048)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func testConfigParsingKeepsOnlyActiveSlots() {
        XCTAssertEqual(sampleConfig.torque, 0); XCTAssertEqual(sampleConfig.rainDelay, 120)
        XCTAssertEqual(sampleConfig.slots.count, 5)
        XCTAssertEqual(sampleConfig.slots.filter(\.second), [ScheduleSlot(day: 2, second: true, start: "15:00", minutes: 60, edgeCut: true)])
        let partial = sampleConfig.merged(with: MowerConfig.parse(["tq": 20]))
        XCTAssertEqual(partial.torque, 20); XCTAssertEqual(partial.rainDelay, 120); XCTAssertEqual(partial.slots.count, 5)
    }
    func testSettingsAlwaysUseStatusCommandAndOnlyTheirKey() throws {
        let torque = try json(.torque(20))
        XCTAssertEqual(Set(torque.keys), ["cmd", "sn", "dt", "tm", "id", "tq"]); XCTAssertEqual(torque["cmd"] as? Int, 0); XCTAssertEqual(torque["tq"] as? Int, 20)
        let rain = try json(.rainDelay(240))
        XCTAssertEqual(Set(rain.keys), ["cmd", "sn", "dt", "tm", "id", "rd"]); XCTAssertEqual(rain["cmd"] as? Int, 0); XCTAssertEqual(rain["rd"] as? Int, 240)
    }
    func testSettingBoundsAreEnforced() {
        XCTAssertThrowsError(try json(.torque(60))); XCTAssertThrowsError(try json(.torque(-51)))
        XCTAssertThrowsError(try json(.rainDelay(-1))); XCTAssertThrowsError(try json(.rainDelay(1441)))
        XCTAssertThrowsError(try json(.slot(ScheduleSlot(day: 9, second: false, start: "09:00", minutes: 60, edgeCut: true))))
        XCTAssertThrowsError(try json(.slot(ScheduleSlot(day: 1, second: false, start: "23:00", minutes: 120, edgeCut: true)))) // past midnight
        XCTAssertThrowsError(try json(.slot(ScheduleSlot(day: 1, second: false, start: "9:00", minutes: 60, edgeCut: true))))
        XCTAssertThrowsError(try json(.slot(ScheduleSlot(day: 1, second: false, start: "09:00", minutes: 0, edgeCut: true))))
        XCTAssertThrowsError(try CommandEnvelope.setting(.torque(10), config: sampleConfig, serial: "TEST", protocolVersion: 1, id: 2048))
        XCTAssertThrowsError(try CommandEnvelope.setting(.removeSlot(day: 0, second: false), config: MowerConfig(), serial: "TEST", protocolVersion: 0, id: 2048))
    }
    func testSlotRewriteOnlyChangesThatSlotAndDropsOneTimeMow() throws {
        let body = try json(.slot(ScheduleSlot(day: 2, second: true, start: "15:00", minutes: 60, edgeCut: false)))
        XCTAssertEqual(body["cmd"] as? Int, 0)
        let sc = try XCTUnwrap(body["sc"] as? [String: Any])
        XCTAssertEqual(Set(sc.keys), ["d", "dd", "m", "p", "distm"])
        XCTAssertEqual(sc["m"] as? Int, 1); XCTAssertEqual(sc["p"] as? Int, -10)
        let original = try XCTUnwrap(sampleConfig.schedule)
        XCTAssertEqual(sc["d"] as? NSArray, original["d"] as? NSArray)
        var expected = try XCTUnwrap(original["dd"] as? [[Any]]); expected[2][2] = 0
        XCTAssertEqual(sc["dd"] as? NSArray, expected as NSArray)
    }
    func testResumeEnvelopeCarriesCurrentStateAndError() throws {
        let data = try CommandEnvelope.data(command: .safeHome, serial: "TEST-ONLY", protocolVersion: 0, capabilities: ["safe_go_home"], id: 4096, resume: (state: 0, error: 4))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["cmd", "sn", "dt", "tm", "id", "ls", "le"])
        XCTAssertEqual(body["cmd"] as? Int, 9); XCTAssertEqual(body["ls"] as? Int, 0); XCTAssertEqual(body["le"] as? Int, 4)
    }
    func testResumeOnlyWithErrorFreshStateAndLiveLink() {
        let now = Date()
        func policy(error: Int, age: Double = 1, connected: Bool = true) -> ControlAvailability {
            ControlAvailability(connected: connected, online: true, protocolVersion: 0, pending: false,
                telemetry: Telemetry.parse(["dat": ["ls": 0, "le": error]], fallbackDate: now.addingTimeInterval(-age)), capabilities: ["safe_go_home"], now: now)
        }
        XCTAssertTrue(policy(error: 4).resume); XCTAssertFalse(policy(error: 0).resume)
        XCTAssertFalse(policy(error: 4, age: 400).resume); XCTAssertFalse(policy(error: 4, connected: false).resume)
        XCTAssertFalse(policy(error: 4).start); XCTAssertFalse(policy(error: 4).home)
    }

    func testSlotsCanBeAddedMovedAndRemovedWithoutOverlap() throws {
        // Add a slot on an empty day, then check where the next one would go.
        let added = try json(.slot(ScheduleSlot(day: 1, second: false, start: "08:30", minutes: 45, edgeCut: false)))
        let d = try XCTUnwrap((added["sc"] as? [String: Any])?["d"] as? [[Any]])
        XCTAssertEqual(d[1] as NSArray, ["08:30", 45, 0] as NSArray)
        XCTAssertEqual(sampleConfig.freePosition(day: 1), false)
        XCTAssertEqual(sampleConfig.freePosition(day: 0), true)
        XCTAssertNil(sampleConfig.freePosition(day: 2))
        // Overlapping the other slot of the same day is refused, touching it is fine.
        XCTAssertThrowsError(try json(.slot(ScheduleSlot(day: 2, second: true, start: "10:30", minutes: 60, edgeCut: true))))
        XCTAssertNoThrow(try json(.slot(ScheduleSlot(day: 2, second: true, start: "11:00", minutes: 60, edgeCut: true))))
        // Removing the first slot moves the second one up.
        let removed = try XCTUnwrap(try json(.removeSlot(day: 2, second: false))["sc"] as? [String: Any])
        XCTAssertEqual((removed["d"] as? [[Any]])?[2] as NSArray?, ["15:00", 60, 1] as NSArray)
        XCTAssertEqual((removed["dd"] as? [[Any]])?[2] as NSArray?, ["00:00", 0, 0] as NSArray)
        let removedSecond = try XCTUnwrap(try json(.removeSlot(day: 2, second: true))["sc"] as? [String: Any])
        XCTAssertEqual((removedSecond["d"] as? [[Any]])?[2] as NSArray?, ["09:00", 120, 1] as NSArray)
    }
    func testEchoConfirmationComparesOnlyWhatWasSent() throws {
        let sent = try json(.torque(20))
        XCTAssertFalse(sampleConfig.reflects(sent))
        XCTAssertTrue(sampleConfig.merged(with: MowerConfig.parse(["tq": 20])).reflects(sent))
        let slot = try json(.removeSlot(day: 6, second: false))
        XCTAssertFalse(sampleConfig.reflects(slot))
        XCTAssertTrue(MowerConfig.parse(["sc": try XCTUnwrap(slot["sc"])]).reflects(slot))
    }
}

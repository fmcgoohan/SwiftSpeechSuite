import Testing
@testable import SwiftLogKit

struct LogKitTests {
    @Test func sfLogSubsystemOverrideTakesEffect() {
        let original = SFLog.subsystem
        defer { SFLog.subsystem = original }

        SFLog.subsystem = "com.example.test"
        // Loggers are opaque; exercising the accessors ensures the override
        // path compiles and produces usable channels without trapping.
        SFLog.pipeline.debug("pipeline channel")
        SFLog.permissions.debug("permissions channel")
        #expect(SFLog.subsystem == "com.example.test")
    }

    @Test func logKitFactoryProducesChannels() {
        let kit = LogKit(subsystem: "com.example.kit")
        kit.pipeline.debug("hello")
        kit.permissions.debug("world")
        let adhoc = LogKit.logger(subsystem: "com.example.kit", category: "adhoc")
        adhoc.debug("adhoc")
    }
}

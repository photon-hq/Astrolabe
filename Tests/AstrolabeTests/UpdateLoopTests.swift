import Network
import Testing
@testable import Astrolabe

@Test func hasNetworkRouteGivesUpAfterTimeout() async {
    // With every interface type prohibited the path can never be satisfied.
    let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.wifi, .wiredEthernet, .cellular, .loopback, .other])
    #expect(await UpdateLoop.hasNetworkRoute(within: .milliseconds(100), monitor: monitor) == false)
}

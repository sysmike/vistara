import Testing

@testable import RDPKit

@Test func swiftCallsIntoTheCShim() {
    #expect(RDPKit.shimInterfaceVersion == 1)
}

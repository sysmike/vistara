import Testing

@testable import VistaraCore

@Test func applicationSupportFolderIsNamedAfterTheApp() {
    #expect(VistaraCore.applicationSupportFolderName == "Vistara")
}

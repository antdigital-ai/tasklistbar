import XCTest
@testable import KeelBar

final class ActivationSchemeResolverTests: XCTestCase {
    func testPrefersSchemeMatchingDisplayName() {
        let info: [String: Any] = [
            "CFBundleDisplayName": "AiWork",
            "CFBundleExecutable": "Electron",
            "CFBundleURLTypes": [[
                "CFBundleURLName": "AiWork",
                "CFBundleURLSchemes": ["dtcoder", "aiwork"]
            ]]
        ]

        XCTAssertEqual(
            ActivationSchemeResolver.candidates(
                infoDictionary: info,
                bundleIdentifier: "com.alipay.dtcoder.ide",
                localizedName: "AiWork"
            ),
            ["aiwork", "dtcoder"]
        )
    }

    func testRejectsGenericDangerousInvalidAndDuplicateSchemes() {
        let info: [String: Any] = [
            "CFBundleName": "Example",
            "CFBundleURLTypes": [
                ["CFBundleURLSchemes": ["https", "example", "EXAMPLE", "bad scheme", "example-oauth"]],
                ["CFBundleURLName": "OAuth Callback", "CFBundleURLSchemes": ["login"]]
            ]
        ]

        XCTAssertEqual(
            ActivationSchemeResolver.candidates(
                infoDictionary: info,
                bundleIdentifier: "com.example.desktop",
                localizedName: nil
            ),
            ["example"]
        )
    }

    func testKeepsDeclaredOrderForUnrelatedButSafeSchemes() {
        let info: [String: Any] = [
            "CFBundleName": "Example",
            "CFBundleURLTypes": [["CFBundleURLSchemes": ["first-protocol", "second-protocol"]]]
        ]

        XCTAssertEqual(
            ActivationSchemeResolver.candidates(
                infoDictionary: info,
                bundleIdentifier: "com.example.desktop",
                localizedName: nil
            ),
            ["first-protocol", "second-protocol"]
        )
    }

    func testDoesNotMistakeProductNameContainingAuthForAuthCallback() {
        let info: [String: Any] = [
            "CFBundleName": "Authy",
            "CFBundleURLTypes": [["CFBundleURLName": "Authy", "CFBundleURLSchemes": ["authy"]]]
        ]

        XCTAssertEqual(
            ActivationSchemeResolver.candidates(
                infoDictionary: info,
                bundleIdentifier: "com.twilio.authy",
                localizedName: "Authy"
            ),
            ["authy"]
        )
    }
}

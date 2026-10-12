import XCTest
@testable import MedPrep

@MainActor final class SiteRegistryTests: XCTestCase {
    func testMainSiteRequiresHTTPSAndNoCredentialsOrAlternatePort() {
        let registry = SiteRegistry()
        XCTAssertTrue(registry.allows(URL(string: "https://new.medpreparation.com/course/view.php?id=1")!))
        for raw in ["http://new.medpreparation.com", "https://new.medpreparation.com.evil.test",
                    "https://new.medpreparation.com:444", "https://user@new.medpreparation.com", "file:///etc/passwd"] {
            XCTAssertFalse(registry.allows(URL(string: raw)!))
        }
    }
    func testEmbedBoundary() {
        let registry = SiteRegistry()
        XCTAssertTrue(registry.embedded(URL(string: "https://www.youtube.com/embed/test")!))
        XCTAssertFalse(registry.embedded(URL(string: "https://notyoutube.com/embed/test")!))
        XCTAssertFalse(registry.embedded(URL(string: "https://youtube.com.evil.test/embed/test")!))
        XCTAssertFalse(registry.embedded(URL(string: "http://youtube.com/embed/test")!))
        XCTAssertFalse(registry.embedded(URL(string: "https://youtube.com:444/embed/test")!))
        XCTAssertFalse(registry.embedded(URL(string: "https://user@youtube.com/embed/test")!))
    }
    func testHostListRejectsInjectedURLsAndMalformedLabels() {
        for host in ["https://example.com", "example.com/path", "*.example.com", "example.com:443", "a..b", "-a.com", "a-.com", ""] {
            XCTAssertFalse(SiteRegistry.validHost(host), host)
        }
        XCTAssertTrue(SiteRegistry.validHost("moodle.example.com"))
    }
}


final class CapturePolicyTests: XCTestCase {
    func testOnlyExactReviewedOSVersionsAndCurrentBuildsAreAllowed() throws {
        let policy = try JSONDecoder().decode(CapturePolicy.self, from: Data(
            #"{"enabled":true,"reviewedOSVersions":["18.0.0"],"minimumBuild":10}"#.utf8))
        XCTAssertTrue(policy.allows(version: "18.0.0", build: 10))
        XCTAssertFalse(policy.allows(version: "18.0.1", build: 10))
        XCTAssertFalse(policy.allows(version: "18.0.0", build: 9))
        let disabled = try JSONDecoder().decode(CapturePolicy.self, from: Data(
            #"{"enabled":false,"reviewedOSVersions":["18.0.0"],"minimumBuild":10}"#.utf8))
        XCTAssertFalse(disabled.allows(version: "18.0.0", build: 10))
    }
    func testUnconfiguredHostCannotPassPinning() {
        XCTAssertFalse(PinnedTrust.configured(host: "unconfigured.invalid"))
    }
    func testSPKIExtractionMatchesOpenSSLForRSAAndEC() {
        // Synthetic public certificates only; these are not deployment pins.
        let fixtures: [(String, String)] = [
            ("MIIDHTCCAgWgAwIBAgIUIQ7MhHL8P57Fgz7hFw9gC4zhGh4wDQYJKoZIhvcNAQELBQAwHjEcMBoGA1UEAwwTcGluLWZpeHR1cmUuaW52YWxpZDAeFw0yNjEwMTIxOTQzMjZaFw0yNjEwMTMxOTQzMjZaMB4xHDAaBgNVBAMME3Bpbi1maXh0dXJlLmludmFsaWQwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDSNJfOKXdMwXPyBTY5YZW7WjZxHiDqY5IlQhT1obIujfGfwWLx0RHy1TBBvzEh/+QTRo0KB1q8b85LfBU2QORcqILvwBBBKvCcBOcEth72UJLNhvvo0mRolbXdOsarXtxO/CXcf1uEG4wLoGHp/gwyq9U2WTK5UPPFijyaV4cynNqKJcYtV+xM3tQOI69Fm1EygaDne9D/CqKUpIkAIdNu6TzA+NZnwbbicRGQkLYHD+T06wd/gCsTz5f6YoPCTsk/QLq66jiMDuzfgDtCJZA6T+tPydn+6y9bGuHWcGL2fMbCpTvHYRYY0RCFHvxDF7tXoL1kmszqm4ET+dpaKPbvAgMBAAGjUzBRMB0GA1UdDgQWBBQiAdWHIb1n/dgPjq05KlDQa7eI2zAfBgNVHSMEGDAWgBQiAdWHIb1n/dgPjq05KlDQa7eI2zAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQAiopRA9rFZWX/a3C1pPNVSg5WKWjlKHGXCEQ2sb/RnwCMS9NhERv4hzQJ5wIrdCbZX9T3Z96ORw/NJgaE0dadRYnF1F1xKEiC9ltiBFSpPXuk9y9ek34iLp/MLCGGTnXb1FOnQesxumZ4ZeDGpi71KCUCmBQyOqCd2cPcRBR6WJgqHhgcb5rXiJYj/ORzTm88I5BPphO2pizvlZK6PoT66fbiiQ5uJHpwGWkmwxSmROKo6hPLSGaYp0jI49FxQRwkK4jO5yyHrI7uVN0OhpepKbwsJaWiQLICDqGH/Fb0aDJJy3nFd2sERAsESSHSwKbyyvNXm9Hh0t21Lt+5uB7vr", "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA0jSXzil3TMFz8gU2OWGVu1o2cR4g6mOSJUIU9aGyLo3xn8Fi8dER8tUwQb8xIf/kE0aNCgdavG/OS3wVNkDkXKiC78AQQSrwnATnBLYe9lCSzYb76NJkaJW13TrGq17cTvwl3H9bhBuMC6Bh6f4MMqvVNlkyuVDzxYo8mleHMpzaiiXGLVfsTN7UDiOvRZtRMoGg53vQ/wqilKSJACHTbuk8wPjWZ8G24nERkJC2Bw/k9OsHf4ArE8+X+mKDwk7JP0C6uuo4jA7s34A7QiWQOk/rT8nZ/usvWxrh1nBi9nzGwqU7x2EWGNEQhR78Qxe7V6C9ZJrM6puBE/naWij27wIDAQAB"),
            ("MIIBkTCCATegAwIBAgIUAbTvdsxwtUg3yrT4Dvefe2soDHUwCgYIKoZIzj0EAwIwHjEcMBoGA1UEAwwTcGluLWZpeHR1cmUuaW52YWxpZDAeFw0yNjEwMTIxOTQzMjZaFw0yNjEwMTMxOTQzMjZaMB4xHDAaBgNVBAMME3Bpbi1maXh0dXJlLmludmFsaWQwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQP7/y/9pZFjjfY87v2rujNTPwFx9uy8gYlUP7np4jfmPDnIcSTUwK/EGXj4+odus7h8rxViAg/hH0tLYczlE2mo1MwUTAdBgNVHQ4EFgQUfe8itECEDuDOd58vUsY2qcgB/1AwHwYDVR0jBBgwFoAUfe8itECEDuDOd58vUsY2qcgB/1AwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEAn+/bZJVZW3MRyQQKaLCrUl4Pe7nO1VwMtFrRj5bgticCIF0kX2ELniRQg1jGyoTS6FRqtFcmqSueHbUVQrlVxMKh", "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAED+/8v/aWRY432PO79q7ozUz8BcfbsvIGJVD+56eI35jw5yHEk1MCvxBl4+PqHbrO4fK8VYgIP4R9LS2HM5RNpg==")
        ]
        for (certificate, expected) in fixtures {
            XCTAssertEqual(PinnedTrust.subjectPublicKeyInfo(Data(base64Encoded: certificate)!), Data(base64Encoded: expected)!)
        }
    }
    func testMalformedCertificateCannotProduceSPKI() {
        for bytes in [[], [0x30, 0x80], [0x30, 0x84, 0xff, 0xff, 0xff, 0xff], [0x30, 1, 0]] {
            XCTAssertNil(PinnedTrust.subjectPublicKeyInfo(Data(bytes.map { UInt8($0) })))
        }
    }
}

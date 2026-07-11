import Foundation
import CryptoKit
import DeviceCheck

/// Signs each scan request with Apple App Attest so the worker can prove the
/// call comes from a genuine, unmodified Tridge install on real Apple hardware —
/// the production replacement for the shipped bearer token.
///
/// Registration is lazy and once-per-install: the first scan generates a Secure
/// Enclave key, attests it against a server challenge, and registers the key
/// with the worker (`POST /v1/attest`). Every scan then signs the exact image
/// bytes (`POST /v1/receipt-scan` with `X-Attest-Key-Id` + `X-Attest-Assertion`).
/// The `keyId` is persisted in `UserDefaults`; App Attest is unavailable on the
/// Simulator, where `authorizationHeaders` throws `LLMError.attestationUnavailable`.
///
/// An `actor` to satisfy `ScanRequestAuthorizer`'s `Sendable` requirement;
/// because `ScanAPIConfig` shares one instance, it also serializes registration
/// so two concurrent scans can't double-attest.
actor AppAttestAuthorizer: ScanRequestAuthorizer {
    private let baseURL: URL
    private let session: URLSession
    private let service = DCAppAttestService.shared

    /// Persisted key id, and whether the worker has accepted its attestation.
    private let keyIDDefaultsKey = "appAttest.keyID"
    private let registeredDefaultsKey = "appAttest.registeredKeyID"
    private let defaults = UserDefaults.standard

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func authorizationHeaders(forImage imageData: Data) async throws -> [String: String] {
        guard service.isSupported else { throw LLMError.attestationUnavailable }
        let keyID = try await registeredKeyID()
        let clientDataHash = Data(SHA256.hash(data: imageData))
        do {
            let assertion = try await generateAssertion(keyID, clientDataHash: clientDataHash)
            return [
                "X-Attest-Key-Id": keyID,
                "X-Attest-Assertion": assertion.base64EncodedString(),
            ]
        } catch let error as DCError where error.code == .invalidKey {
            // The stored key is gone (e.g. device restored) — start over once.
            AppLog.scan.error("App Attest key invalid; re-attesting")
            forget()
            let freshKey = try await registeredKeyID()
            let assertion = try await generateAssertion(freshKey, clientDataHash: clientDataHash)
            return [
                "X-Attest-Key-Id": freshKey,
                "X-Attest-Assertion": assertion.base64EncodedString(),
            ]
        }
    }

    /// A key id whose attestation the worker has accepted, generating and
    /// registering one on first use (or after a previous registration failed).
    private func registeredKeyID() async throws -> String {
        let keyID = try await existingOrNewKeyID()
        if defaults.string(forKey: registeredDefaultsKey) == keyID { return keyID }

        let challenge = try await fetchChallenge()
        guard let challengeData = Data(base64Encoded: challenge) else {
            throw LLMError.attestationUnavailable
        }
        let attestation = try await attestKey(keyID, clientDataHash: Data(SHA256.hash(data: challengeData)))
        try await register(keyID: keyID, attestation: attestation, challenge: challenge)
        defaults.set(keyID, forKey: registeredDefaultsKey)
        return keyID
    }

    private func existingOrNewKeyID() async throws -> String {
        if let keyID = defaults.string(forKey: keyIDDefaultsKey) { return keyID }
        let keyID = try await generateKey()
        defaults.set(keyID, forKey: keyIDDefaultsKey)
        return keyID
    }

    /// The worker rejected a scan (401) — most often because it no longer has
    /// this device's record (its KV entry expired or the namespace was reset).
    /// Drop the local registration so the retry re-attests; always worth one try.
    func invalidate() -> Bool {
        AppLog.scan.error("Scan rejected (401); clearing App Attest registration to re-attest")
        forget()
        return true
    }

    private func forget() {
        defaults.removeObject(forKey: keyIDDefaultsKey)
        defaults.removeObject(forKey: registeredDefaultsKey)
    }

    // MARK: Worker calls

    private struct ChallengeResponse: Decodable { let challenge: String }

    private func fetchChallenge() async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/attest/challenge"))
        request.httpMethod = "POST"
        let (data, response) = try await session.data(for: request)
        try Self.ensureOK(response, data: data)
        return try JSONDecoder().decode(ChallengeResponse.self, from: data).challenge
    }

    private func register(keyID: String, attestation: Data, challenge: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/attest"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "keyId": keyID,
            "attestation": attestation.base64EncodedString(),
            "challenge": challenge,
        ])
        let (data, response) = try await session.data(for: request)
        try Self.ensureOK(response, data: data)
    }

    private static func ensureOK(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw LLMError.network(underlying: nil) }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(decoding: data.prefix(200), as: UTF8.self)
            AppLog.scan.error("App Attest worker call failed HTTP \(http.statusCode): \(body)")
            throw LLMError.apiFailure(status: http.statusCode)
        }
    }

    // MARK: DCAppAttestService async bridges (completion-handler API only)

    private func generateKey() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            service.generateKey { keyID, error in
                if let keyID { continuation.resume(returning: keyID) }
                else { continuation.resume(throwing: error ?? LLMError.attestationUnavailable) }
            }
        }
    }

    private func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            service.attestKey(keyID, clientDataHash: clientDataHash) { attestation, error in
                if let attestation { continuation.resume(returning: attestation) }
                else { continuation.resume(throwing: error ?? LLMError.attestationUnavailable) }
            }
        }
    }

    private func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            service.generateAssertion(keyID, clientDataHash: clientDataHash) { assertion, error in
                if let assertion { continuation.resume(returning: assertion) }
                else { continuation.resume(throwing: error ?? LLMError.attestationUnavailable) }
            }
        }
    }
}

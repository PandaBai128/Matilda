import Foundation

struct CodexUsageClient {
    private let urlSession: URLSession
    private let environment: [String: String]
    private let fileManager: FileManager

    init(
        urlSession: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.urlSession = urlSession
        self.environment = environment
        self.fileManager = fileManager
    }

    func fetchSnapshot() async throws -> CodexUsageSnapshot {
        let credentials = try loadCredentials()
        var request = URLRequest(
            url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("Matilda", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountIdentifier = credentials.accountIdentifier {
            request.setValue(accountIdentifier, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (responseData, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CodexUsageError.invalidResponse
            }
            switch httpResponse.statusCode {
            case 200...299:
                do {
                    return try CodexUsageSnapshot.decode(
                        responseData: responseData,
                        refreshedAt: Date()
                    )
                } catch {
                    throw CodexUsageError.invalidResponse
                }
            case 401, 403:
                throw CodexUsageError.unauthorized
            default:
                throw CodexUsageError.serverError(httpResponse.statusCode)
            }
        } catch let codexUsageError as CodexUsageError {
            throw codexUsageError
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexUsageError.networkUnavailable
        }
    }

    private func loadCredentials() throws -> CodexUsageCredentials {
        let authenticationFileURL = codexHomeDirectoryURL()
            .appendingPathComponent("auth.json", isDirectory: false)
        guard fileManager.fileExists(atPath: authenticationFileURL.path) else {
            throw CodexUsageError.credentialsNotFound
        }

        do {
            let authenticationData = try Data(contentsOf: authenticationFileURL)
            let authenticationFile = try JSONDecoder().decode(
                CodexAuthenticationFile.self,
                from: authenticationData
            )
            guard let tokens = authenticationFile.tokens,
                  !tokens.accessToken.isEmpty
            else {
                throw CodexUsageError.credentialsInvalid
            }
            return CodexUsageCredentials(
                accessToken: tokens.accessToken,
                accountIdentifier: tokens.accountIdentifier
            )
        } catch let codexUsageError as CodexUsageError {
            throw codexUsageError
        } catch {
            throw CodexUsageError.credentialsInvalid
        }
    }

    private func codexHomeDirectoryURL() -> URL {
        if let configuredCodexHomePath = environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configuredCodexHomePath.isEmpty
        {
            return URL(fileURLWithPath: configuredCodexHomePath, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }
}

private struct CodexUsageCredentials {
    let accessToken: String
    let accountIdentifier: String?
}

private struct CodexAuthenticationFile: Decodable {
    let tokens: Tokens?

    struct Tokens: Decodable {
        let accessToken: String
        let accountIdentifier: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountIdentifier = "account_id"
        }
    }
}

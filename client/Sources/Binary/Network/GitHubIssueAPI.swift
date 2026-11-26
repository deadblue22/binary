import Foundation

struct GitHubIssueDetails: Decodable, Sendable {
    enum Status: Int { case open, draft, merged, closed }
    private enum State: String, Decodable { case open, closed }
    private struct PullRequest: Decodable, Sendable {
        let mergedAt: String?
        enum CodingKeys: String, CodingKey { case mergedAt = "merged_at" }
    }

    struct Author: Decodable, Sendable { let login: String }
    struct Branch: Decodable, Sendable { let ref: String }

    enum CodingKeys: String, CodingKey {
        case title, state, draft, user, body, head, base
        case mergedAt = "merged_at"
        case updatedAt = "updated_at"
        case pullRequest = "pull_request"
    }

    let user: Author?
    let head: Branch?
    let base: Branch?
    let body: String?
    private let mergedAt: String?
    let title: String
    let updatedAt: Date
    private let state: State
    private let draft: Bool?
    private let pullRequest: PullRequest?

    var kind: String { pullRequest != nil || head != nil ? "PR" : "Issue" }
    var status: Status {
        if mergedAt != nil || pullRequest?.mergedAt != nil { return .merged }
        if state == .closed { return .closed }
        if draft == true { return .draft }
        return .open
    }
}

struct GitHubIssueAPI {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    /// Use the Mac's existing github.com login, including when launched from Finder.
    /// The credential is used only for requests to the fixed GitHub API host.
    private static func credential() async -> String? {
        #if os(macOS)
        let paths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/opt/local/bin/gh"]
        guard let path = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["auth", "token", "--hostname", "github.com"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { return nil }
        #else
        return nil
        #endif
    }

    private static func details(for ref: GitHubReference, server: APIClient?, token: String?) async -> GitHubIssueDetails? {
        func read(pull: Bool) async -> GitHubIssueDetails? {
            guard !Task.isCancelled else { return nil }
            if let server, let details: GitHubIssueDetails = try? await server.get("/github/issue", query: [
                "repository": ref.repository, "number": ref.number, "kind": pull ? "PR" : "Issue"
            ]) { return details }
            guard !Task.isCancelled else { return nil }
            let url = URL(string: "https://api.github.com/repos")!
                .appendingPathComponent(ref.repository)
                .appendingPathComponent(pull ? "pulls" : "issues")
                .appendingPathComponent(ref.number)
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            do {
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(GitHubIssueDetails.self, from: data)
            } catch { return nil }
        }
        if ref.kind == "PR", let pull = await read(pull: true) { return pull }
        let issue = await read(pull: false)
        // An untyped owner/repo#number can turn out to be a pull request.
        if ref.kind != "PR", issue?.kind == "PR", issue?.user != nil {
            return await read(pull: true) ?? issue
        }
        return issue
    }

    static func load(_ refs: [GitHubReference], server: APIClient?,
                     receive: @MainActor (String, GitHubIssueDetails?) -> Void) async {
        guard !refs.isEmpty else { return }
        let token = await credential()
        await withTaskGroup(of: (String, GitHubIssueDetails?).self) { group in
            var remaining = refs.makeIterator()
            func enqueueNext() {
                if let ref = remaining.next() {
                    group.addTask { (ref.id, await details(for: ref, server: server, token: token)) }
                }
            }
            for _ in 0..<min(4, refs.count) { enqueueNext() }
            for await (id, details) in group {
                guard !Task.isCancelled else { return }
                await receive(id, details)
                enqueueNext()
            }
        }
    }
}

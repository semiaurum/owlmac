import AppKit

/// Checks GitHub Releases for a newer OwlMac and swaps the app bundle the way install.sh does.
@MainActor
final class Updater {
    struct Release: Sendable {
        let version: Version
        let zipURL: URL
        let pageURL: URL
    }

    /// Dotted numeric version. Non-numeric parts count as 0, so 0.10.1 is newer than 0.9.3.
    struct Version: Comparable, Sendable, CustomStringConvertible {
        let text: String
        private let parts: [Int]

        init(_ text: String) {
            self.text = text.hasPrefix("v") ? String(text.dropFirst()) : text
            parts = self.text.split(separator: ".").map { Int($0) ?? 0 }
        }

        var description: String { text }

        static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }

        static func < (a: Version, b: Version) -> Bool {
            for i in 0..<max(a.parts.count, b.parts.count) {
                let x = i < a.parts.count ? a.parts[i] : 0
                let y = i < b.parts.count ? b.parts[i] : 0
                if x != y { return x < y }
            }
            return false
        }
    }

    enum Outcome: Sendable {
        case upToDate(Version)
        case newer(Release)
        /// A bare `swiftc` binary or a build that skipped the VERSION substitution.
        case unversioned
    }

    enum UpdateError: LocalizedError {
        case badStatus(Int?)
        case malformedRelease
        case missingAsset(Version)
        case downloadFailed

        var errorDescription: String? {
            switch self {
            case .badStatus(let code?): "GitHub이 \(code)으로 답했어요."
            case .badStatus(nil): "응답이 없어요."
            case .malformedRelease: "릴리스 정보를 읽지 못했어요."
            case .missingAsset(let version): "v\(version) 릴리스에 OwlMac.zip이 없어요."
            case .downloadFailed: "OwlMac.zip을 내려받지 못했어요."
            }
        }
    }

    /// owner/repo. `defaults write io.github.owlmac updateRepo owner/repo` follows a fork (like OWLMAC_REPO in install.sh).
    private let repo: String
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var inFlight: Task<Outcome, Error>?

    /// The newest release seen that is newer than the running app. Shown at the top of the menu.
    private(set) var available: Release?
    /// Called each time an automatic check finds a newer version. The app decides whether to ask or install.
    var onAutoFound: (@MainActor (Release) -> Void)?

    nonisolated init() {
        repo = UserDefaults.standard.string(forKey: "updateRepo") ?? "semiaurum/owlmac"
    }

    nonisolated static let currentVersion: Version? = {
        guard let text = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              !text.isEmpty, text != "__VERSION__" else { return nil }
        return Version(text)
    }()

    var autoCheck: Bool {
        get { defaults.bool(forKey: "autoUpdateCheck") }
        set {
            defaults.set(newValue, forKey: "autoUpdateCheck")
            scheduleAutoCheck()
        }
    }

    /// Install a found release without asking, as long as nothing is being kept awake.
    var autoInstall: Bool {
        get { defaults.bool(forKey: "autoUpdateInstall") }
        set { defaults.set(newValue, forKey: "autoUpdateInstall") }
    }

    // MARK: Scheduling

    /// Checks shortly after launch and then once a day while auto-check is on.
    func scheduleAutoCheck() {
        timer?.invalidate()
        timer = nil
        guard autoCheck, Updater.currentVersion != nil else { return }

        let timer = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.runAutoCheck() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.autoCheck else { return }
            await self.runAutoCheck()
        }
    }

    private func runAutoCheck() async {
        guard let outcome = try? await check(), case .newer(let release) = outcome else { return }
        onAutoFound?(release)
    }

    // MARK: Checking

    /// Asks GitHub for the latest release. Concurrent callers share one request.
    @discardableResult
    func check() async throws -> Outcome {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await self.fetchLatest() }
        inFlight = task
        defer { inFlight = nil }

        let outcome = try await task.value
        switch outcome {
        case .newer(let release): available = release
        case .upToDate: available = nil
        case .unversioned: break
        }
        return outcome
    }

    private struct LatestRelease: Decodable {
        let tagName: String
        let htmlURL: URL
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    private func fetchLatest() async throws -> Outcome {
        guard let current = Updater.currentVersion else { return .unversioned }

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OwlMac/\(current)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        guard status == 200 else { throw UpdateError.badStatus(status) }

        let latest: LatestRelease
        do {
            latest = try JSONDecoder().decode(LatestRelease.self, from: data)
        } catch {
            throw UpdateError.malformedRelease
        }

        let version = Version(latest.tagName)
        guard version > current else { return .upToDate(current) }
        guard let zip = latest.assets.first(where: { $0.name == "OwlMac.zip" }) else {
            throw UpdateError.missingAsset(version)
        }
        return .newer(Release(version: version, zipURL: zip.browserDownloadURL, pageURL: latest.htmlURL))
    }

    // MARK: Installing

    /// Downloads the zip, then starts a script that waits for this process to quit, swaps the bundle
    /// (unzip → replace → drop quarantine, as install.sh does) and relaunches. The caller quits the app
    /// afterwards so applicationWillTerminate can release assertions and undo `pmset disablesleep`.
    func install(_ release: Release) async throws {
        let (downloaded, response) = try await URLSession.shared.download(for: URLRequest(url: release.zipURL))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.downloadFailed }
        try launchSwapScript(zipAt: downloaded)
    }

    /// Where the new bundle goes: the running bundle if its folder is writable, else /Applications, else ~/Applications.
    private var destination: URL {
        let fm = FileManager.default
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app", fm.isWritableFile(atPath: bundle.deletingLastPathComponent().path) {
            return bundle
        }
        let apps = URL(fileURLWithPath: "/Applications")
        if fm.isWritableFile(atPath: apps.path) { return apps.appendingPathComponent("OwlMac.app") }
        return fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/OwlMac.app")
    }

    private func launchSwapScript(zipAt downloaded: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("OwlMac-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("OwlMac.zip")
        try fm.moveItem(at: downloaded, to: zip)

        let script = """
        #!/bin/bash
        # Written by OwlMac to finish an update after the app has quit.
        set -u
        pid=\(ProcessInfo.processInfo.processIdentifier)
        zip=\(Self.quoted(zip.path))
        work=\(Self.quoted(work.path))
        dest=\(Self.quoted(destination.path))
        for _ in $(seq 1 150); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
        ditto -x -k "$zip" "$work" || exit 1
        [ -d "$work/OwlMac.app" ] || exit 1
        mkdir -p "$(dirname "$dest")"
        rm -rf "$dest"
        ditto "$work/OwlMac.app" "$dest" || exit 1
        xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
        open "$dest"
        rm -rf "$work"
        """
        let scriptURL = work.appendingPathComponent("swap.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

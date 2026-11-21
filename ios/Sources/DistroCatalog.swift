// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct DistroCatalogItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let subtitle: String
    let distroTag: String
    let downloadURL: URL
    let fileName: String
    let approxSizeLabel: String
    let recommendedDiskGiB: Int
    let recommendedGpuBackend: Int
    let needsCidata: Bool

    static let firmwareCodeURL = URL(
        string: "https://github.com/venim1103/henge-linux/releases/download/latest-ipa/code.fd"
    )!
    static let firmwareVarsURL = URL(
        string: "https://github.com/venim1103/henge-linux/releases/download/latest-ipa/vars.fd"
    )!

    static let supportedDistros: [DistroCatalogItem] = [
        DistroCatalogItem(
            id: "arch-prebuilt",
            name: "Arch Linux ARM (Prebuilt)",
            subtitle: "Preconfigured HengeLinux image · root autologin · LXQt helper included",
            distroTag: "arch",
            downloadURL: URL(string: "https://github.com/venim1103/henge-linux/releases/download/latest-ipa/archlinux.hvsparse")!,
            fileName: "archlinux.hvsparse",
            approxSizeLabel: "~310 MiB",
            recommendedDiskGiB: 16,
            recommendedGpuBackend: 0,
            needsCidata: false
        ),
        DistroCatalogItem(
            id: "debian-13-generic",
            name: "Debian 13 (Trixie) ARM64",
            subtitle: "Official generic QCOW2 · VirtIO-GPU KMS · bash + cloud-init ready",
            distroTag: "debian",
            downloadURL: URL(string: "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-arm64.qcow2")!,
            fileName: "debian-13-generic-arm64.qcow2",
            approxSizeLabel: "~390 MiB",
            recommendedDiskGiB: 16,
            recommendedGpuBackend: 2,
            needsCidata: true
        ),
        DistroCatalogItem(
            id: "ubuntu-2404-lts",
            name: "Ubuntu 24.04 LTS (Noble) ARM64",
            subtitle: "Official Cloud QCOW2 · 2D UEFI GOP (works out-of-box) · bash + trimmed daemons",
            distroTag: "ubuntu",
            downloadURL: URL(string: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img")!,
            fileName: "ubuntu-24.04-server-cloudimg-arm64.img",
            approxSizeLabel: "~620 MiB",
            recommendedDiskGiB: 16,
            recommendedGpuBackend: 0,
            needsCidata: true
        ),
        DistroCatalogItem(
            id: "ubuntu-2604-lts",
            name: "Ubuntu 26.04 LTS (Resolute) ARM64",
            subtitle: "Official Cloud QCOW2 · Newer kernel · 2D UEFI GOP + bash",
            distroTag: "ubuntu",
            downloadURL: URL(string: "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-arm64.img")!,
            fileName: "ubuntu-26.04-server-cloudimg-arm64.img",
            approxSizeLabel: "~900 MiB",
            recommendedDiskGiB: 16,
            recommendedGpuBackend: 0,
            needsCidata: true
        ),
        DistroCatalogItem(
            id: "alpine-323-cloud",
            name: "Alpine Linux 3.23 ARM64",
            subtitle: "Ultra-lightweight musl + OpenRC UEFI QCOW2 · fast boot",
            distroTag: "alpine",
            downloadURL: URL(string: "https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/cloud/alpine-3.23.6-aarch64-uefi-cloudinit-r0.qcow2")!,
            fileName: "alpine-3.23.6-aarch64-uefi-cloudinit-r0.qcow2",
            approxSizeLabel: "~237 MiB",
            recommendedDiskGiB: 8,
            recommendedGpuBackend: 0,
            needsCidata: true
        ),
        DistroCatalogItem(
            id: "fedora-43-cloud",
            name: "Fedora 43 Cloud Base ARM64",
            subtitle: "Official Btrfs + SELinux QCOW2 · VirtIO-GPU KMS + bash",
            distroTag: "fedora",
            downloadURL: URL(string: "https://download.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/aarch64/images/Fedora-Cloud-Base-Generic-43-1.6.aarch64.qcow2")!,
            fileName: "Fedora-Cloud-Base-Generic-43-1.6.aarch64.qcow2",
            approxSizeLabel: "~520 MiB",
            recommendedDiskGiB: 16,
            recommendedGpuBackend: 2,
            needsCidata: true
        ),
        DistroCatalogItem(
            id: "opensuse-tumbleweed",
            name: "openSUSE Tumbleweed Cloud ARM64",
            subtitle: "Rolling Minimal-VM QCOW2 · VirtIO-GPU KMS + bash",
            distroTag: "opensuse",
            downloadURL: URL(string: "https://download.opensuse.org/ports/aarch64/tumbleweed/appliances/openSUSE-Tumbleweed-Minimal-VM.aarch64-Cloud.qcow2")!,
            fileName: "openSUSE-Tumbleweed-Minimal-VM.aarch64-Cloud.qcow2",
            approxSizeLabel: "~340 MiB",
            recommendedDiskGiB: 16,
            recommendedGpuBackend: 2,
            needsCidata: true
        )
    ]
}

/// Streams public ARM64 cloud images and shared EDK2 UEFI firmware directly to
/// disk via `URLSessionDownloadTask` with zero RAM buffering and cancellation.
@MainActor
final class DistroDownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published private(set) var isDownloading: Bool = false
    @Published private(set) var activeTitle: String = ""
    @Published private(set) var progressFraction: Double = 0.0
    @Published private(set) var bytesDownloaded: Int64 = 0
    @Published private(set) var bytesExpected: Int64 = 0
    @Published private(set) var lastError: String?

    private var urlSession: URLSession?
    private var activeTask: URLSessionDownloadTask?
    private var activeContinuation: CheckedContinuation<URL, Error>?

    var progressLabel: String {
        let dlMiB = Double(bytesDownloaded) / (1024.0 * 1024.0)
        if bytesExpected > 0 {
            let totalMiB = Double(bytesExpected) / (1024.0 * 1024.0)
            let pct = Int((progressFraction * 100.0).rounded())
            return String(format: "%.1f / %.1f MiB (%d%%)", dlMiB, totalMiB, pct)
        }
        return String(format: "%.1f MiB downloaded...", dlMiB)
    }

    func cancelDownload() {
        activeTask?.cancel()
        activeTask = nil
        if let cont = activeContinuation {
            activeContinuation = nil
            cont.resume(throwing: CancellationError())
        }
        isDownloading = false
        activeTitle = ""
        progressFraction = 0.0
        bytesDownloaded = 0
        bytesExpected = 0
    }

    func downloadFile(from url: URL, title: String) async throws -> URL {
        guard !isDownloading else {
            throw NSError(
                domain: "io.hengelinux.download",
                code: 4001,
                userInfo: [NSLocalizedDescriptionKey: "Another download is already in progress."]
            )
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw NSError(
                domain: "io.hengelinux.download",
                code: 4002,
                userInfo: [NSLocalizedDescriptionKey: "Only http:// and https:// download URLs are supported."]
            )
        }

        if urlSession == nil {
            let config = URLSessionConfiguration.default
            config.waitsForConnectivity = true
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 3600
            urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        }

        isDownloading = true
        activeTitle = title
        progressFraction = 0.0
        bytesDownloaded = 0
        bytesExpected = 0
        lastError = nil

        defer {
            isDownloading = false
            activeTitle = ""
            activeTask = nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.activeContinuation = continuation
            var req = URLRequest(url: url)
            req.setValue("HengeLinux/0.2 (iOS ARM64)", forHTTPHeaderField: "User-Agent")
            let task = self.urlSession!.downloadTask(with: req)
            self.activeTask = task
            task.resume()
        }
    }

    func downloadSharedFirmware(into vmStore: VMStore) async throws {
        let codeTmp = try await downloadFile(
            from: DistroCatalogItem.firmwareCodeURL,
            title: "UEFI Firmware (code.fd)"
        )
        defer { try? FileManager.default.removeItem(at: codeTmp) }

        let varsTmp = try await downloadFile(
            from: DistroCatalogItem.firmwareVarsURL,
            title: "UEFI NVRAM Template (vars.fd)"
        )
        defer { try? FileManager.default.removeItem(at: varsTmp) }

        try vmStore.installSharedFirmware(codeTempURL: codeTmp, varsTempURL: varsTmp)
    }

    func downloadAndProvision(
        item: DistroCatalogItem,
        into vmStore: VMStore,
        ramMiB: Int,
        cpuCount: Int,
        diskGiB: Int,
        username: String,
        password: String
    ) async throws -> VMConfig {
        if !vmStore.hasSharedFirmware {
            try await downloadSharedFirmware(into: vmStore)
        }

        let stagedURL = try await downloadFile(from: item.downloadURL, title: item.name)
        defer { try? FileManager.default.removeItem(at: stagedURL) }

        let targetGiB = max(diskGiB, item.recommendedDiskGiB)
        let vm = try vmStore.createMachine(
            name: item.name,
            distroTag: item.distroTag,
            ramMiB: ramMiB,
            cpuCount: cpuCount,
            gpuBackend: item.recommendedGpuBackend,
            targetDiskSizeGiB: targetGiB
        )

        do {
            _ = try vmStore.importStagedGuestFile(
                from: stagedURL,
                originalFileName: item.fileName,
                into: vm
            )
            if item.needsCidata {
                let latestVM = vmStore.machines.first(where: { $0.id == vm.id }) ?? vm
                let hostSlug = item.distroTag == "linux" ? "hengelinux" : "\(item.distroTag)-ios"
                _ = try vmStore.generateCidataSeed(
                    for: latestVM,
                    hostname: hostSlug,
                    username: username,
                    password: password
                )
            }
            return vmStore.machines.first(where: { $0.id == vm.id }) ?? vm
        } catch {
            try? vmStore.deleteMachine(id: vm.id)
            throw error
        }
    }

    func downloadCustomURL(
        _ url: URL,
        vmName: String,
        distroTag: String,
        into vmStore: VMStore,
        ramMiB: Int,
        cpuCount: Int,
        diskGiB: Int,
        generateCidata: Bool,
        username: String,
        password: String
    ) async throws -> VMConfig {
        if !vmStore.hasSharedFirmware {
            try await downloadSharedFirmware(into: vmStore)
        }

        let rawFileName = url.lastPathComponent.isEmpty ? "disk0.qcow2" : url.lastPathComponent
        let displayTitle = vmName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? rawFileName : vmName
        let stagedURL = try await downloadFile(from: url, title: displayTitle)
        defer { try? FileManager.default.removeItem(at: stagedURL) }

        let vm = try vmStore.createMachine(
            name: displayTitle,
            distroTag: distroTag,
            ramMiB: ramMiB,
            cpuCount: cpuCount,
            gpuBackend: ["debian", "fedora", "opensuse"].contains(distroTag) ? 2 : 0,
            targetDiskSizeGiB: max(diskGiB, 8)
        )

        do {
            if rawFileName.lowercased().hasSuffix(".iso") {
                try vmStore.createBlankDisk(for: vm, sizeGiB: max(diskGiB, 16))
            }
            let currentVM = vmStore.machines.first(where: { $0.id == vm.id }) ?? vm
            _ = try vmStore.importStagedGuestFile(
                from: stagedURL,
                originalFileName: rawFileName,
                into: currentVM
            )
            if generateCidata && !rawFileName.lowercased().hasSuffix(".iso") {
                let latestVM = vmStore.machines.first(where: { $0.id == vm.id }) ?? currentVM
                _ = try vmStore.generateCidataSeed(
                    for: latestVM,
                    hostname: "\(distroTag)-ios",
                    username: username,
                    password: password
                )
            }
            return vmStore.machines.first(where: { $0.id == vm.id }) ?? vm
        } catch {
            try? vmStore.deleteMachine(id: vm.id)
            throw error
        }
    }

    private func finishActiveDownload(_ result: Result<URL, Error>) {
        guard let cont = activeContinuation else {
            return
        }
        activeContinuation = nil
        activeTask = nil
        switch result {
        case .success(let url):
            progressFraction = 1.0
            cont.resume(returning: url)
        case .failure(let error):
            if !(error is CancellationError) {
                lastError = error.localizedDescription
            }
            cont.resume(throwing: error)
        }
    }

    // MARK: - URLSessionDownloadDelegate

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.bytesDownloaded = totalBytesWritten
            self.bytesExpected = totalBytesExpectedToWrite
            if totalBytesExpectedToWrite > 0 {
                self.progressFraction = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0.0), 1.0)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            let err = NSError(
                domain: "io.hengelinux.download",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Server returned HTTP \(http.statusCode) for \(downloadTask.originalRequest?.url?.lastPathComponent ?? "file")."]
            )
            Task { @MainActor [weak self] in
                self?.finishActiveDownload(.failure(err))
            }
            return
        }

        let suggested = downloadTask.response?.suggestedFilename
            ?? downloadTask.originalRequest?.url?.lastPathComponent
            ?? "image.bin"
        let cleanName = suggested.replacingOccurrences(of: "/", with: "_")
        let stagedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("henge-dl-\(UUID().uuidString)-\(cleanName)")

        do {
            if FileManager.default.fileExists(atPath: stagedURL.path) {
                try FileManager.default.removeItem(at: stagedURL)
            }
            try FileManager.default.moveItem(at: location, to: stagedURL)
            Task { @MainActor [weak self] in
                self?.finishActiveDownload(.success(stagedURL))
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.finishActiveDownload(.failure(error))
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        Task { @MainActor [weak self] in
            self?.finishActiveDownload(.failure(error))
        }
    }
}

import Foundation
import GTProtocol
import GTSecurity
import GTCapture
import GTInput
import GTAdapters
import WebRTC

/// Glues a connected device's WebRTC peer to host-level remote apps.
///
/// Responsibilities:
/// - Receive `DataChannelMessage` from the phone and route input to the correct
///   `AgentAdapter` (honoring read-only mode and auto-lock).
/// - Push `AgentStateSnapshot` from each adapter into the phone's DataChannel.
/// - Start/stop `WindowCapture` streams for cells with `videoEnabled == true`
///   and hand the frames to WebRTC video sources.
/// - Emit signed `AgentStateEvent` envelopes to the signaling server on status
///   transitions so Web Push can fire to offline phones.
@MainActor
public final class Session {
    public let peer: WebRTCPeer
    public let phoneDeviceID: DeviceID
    public let hostDeviceKey: DeviceKey
    public let signaling: SignalingClient
    public let autoLock: AutoLock
    public let redactor: SecretRedactor

    private let remoteAppController: RemoteAppController
    #if os(macOS)
    private var captures: [AgentID: any VideoCaptureBinding] = [:]
    private var captureReconcilers: [AgentID: AsyncLatestStateReconciler<RemoteApp?>] = [:]
    #endif
    private var currentLayout: GridLayout
    private var currentRemoteApps: [RemoteApp]
    private var readOnlyMode: Bool = false
    private var isStopping = false
    private var imageTransfers: [String: PendingImageTransfer] = [:]
    private var fileAttachmentBatches: [String: PendingFileAttachmentBatch] = [:]

    public init(
        peer: WebRTCPeer,
        phoneDeviceID: DeviceID,
        hostDeviceKey: DeviceKey,
        signaling: SignalingClient,
        autoLock: AutoLock,
        redactor: SecretRedactor = SecretRedactor(),
        remoteAppController: RemoteAppController
    ) {
        self.peer = peer
        self.phoneDeviceID = phoneDeviceID
        self.hostDeviceKey = hostDeviceKey
        self.signaling = signaling
        self.autoLock = autoLock
        self.redactor = redactor
        self.remoteAppController = remoteAppController
        self.currentRemoteApps = remoteAppController.remoteAppsSnapshot()
        self.currentLayout = remoteAppController.deprecatedLayout()

        peer.onDataChannelMessage = { [weak self] msg in
            guard let session = self else { return }
            Task { @MainActor [session] in
                session.handleDataChannelMessage(msg)
            }
        }
    }

    // MARK: - Lifecycle

    public func start(hostDeviceLabel: String) {
        isStopping = false
        peer.ensureDataChannel()
        sendHello(deviceLabel: hostDeviceLabel)
        sendRemoteApps(currentRemoteApps)
        for snapshot in remoteAppController.cachedSnapshots() {
            sendAgentState(snapshot)
        }
        applyRemoteApps(currentRemoteApps)
    }

    @discardableResult
    public func stop() -> Task<Void, Never> {
        isStopping = true
        #if os(macOS)
        let agentIDs = Set(captures.keys).union(captureReconcilers.keys)
        let reconcilers = agentIDs.map { agentID in
            peer.removeVideoTrack(agentID: agentID)
            let reconciler = captureReconciler(for: agentID)
            reconciler.setDesired(nil)
            return reconciler
        }
        return Task { @MainActor in
            for reconciler in reconcilers {
                await reconciler.waitUntilSettled()
            }
        }
        #else
        return Task {}
        #endif
    }

    #if os(macOS)
    public func prepareMediaForOffer() async {
        let desiredApps = desiredVideoApps(from: currentRemoteApps)
        let reconcilers = desiredApps.map { agentID, app in
            let reconciler = captureReconciler(for: agentID)
            reconciler.setDesired(app)
            return reconciler
        }
        for reconciler in reconcilers {
            await reconciler.waitUntilSettled()
        }
    }
    #else
    public func prepareMediaForOffer() async {}
    #endif

    // MARK: - Remote apps

    public func applyRemoteApps(_ remoteApps: [RemoteApp]) {
        #if os(macOS)
        let previousVideoAgentIDs = Set(currentRemoteApps.filter(\.hasVideo).map(\.agentId))
        #endif
        currentRemoteApps = remoteApps
        currentLayout = remoteAppController.deprecatedLayout()

        #if os(macOS)
        let desiredApps = desiredVideoApps(from: remoteApps)
        let agentIDs = previousVideoAgentIDs
            .union(desiredApps.keys)
            .union(captures.keys)
            .union(captureReconcilers.keys)
        for agentID in agentIDs {
            captureReconciler(for: agentID).setDesired(desiredApps[agentID])
        }
        #endif

        sendRemoteApps(remoteApps)
        try? peer.send(DataChannelMessage(body: .gridLayoutUpdate(GridLayoutUpdate(layout: currentLayout))))
    }

    public func sendAgentState(_ snapshot: AgentStateSnapshot) {
        try? peer.send(DataChannelMessage(body: .agentState(snapshot)))
        let event = AgentStateEvent(
            agentId: snapshot.agentId,
            status: snapshot.status,
            summary: snapshot.statusDetail
        )
        let envelope = Envelope(
            fromDeviceId: hostDeviceKey.deviceId,
            toDeviceId: phoneDeviceID,
            payload: .agentStateEvent(event)
        )
        Task { [signaling] in
            try? await signaling.send(envelope)
        }
    }

    private func sendRemoteApps(_ remoteApps: [RemoteApp]) {
        try? peer.send(DataChannelMessage(body: .remoteAppsUpdate(RemoteAppsUpdate(remoteApps: remoteApps))))
    }

    // MARK: - DataChannel incoming

    private func handleDataChannelMessage(_ msg: DataChannelMessage) {
        autoLock.heartbeat()
        switch msg.body {
        case .userInput(let input):
            sendInputToRemoteApp(
                agentId: input.agentId,
                text: input.text,
                submit: input.submitOnSend,
                failureLabel: "message"
            )
        case .imageAttachmentInput(let input):
            guard canAcceptInput(agentId: input.agentId) else { return }
            Task { [weak self] in
                await self?.handleImageAttachment(input)
            }
        case .imageAttachmentChunk(let chunk):
            guard canAcceptInput(agentId: chunk.agentId) else { return }
            Task { [weak self] in
                await self?.handleImageAttachmentChunk(chunk)
            }
        case .fileAttachmentChunk(let chunk):
            guard canAcceptInput(agentId: chunk.agentId) else { return }
            Task { [weak self] in
                await self?.handleFileAttachmentChunk(chunk)
            }
        case .quickReply(let reply):
            sendInputToRemoteApp(
                agentId: reply.agentId,
                text: reply.kind.literalText,
                submit: true,
                failureLabel: "quick reply"
            )
        case .interruptRequest(let req):
            guard canAcceptInput(agentId: req.agentId) else { return }
            Task { [weak self, controller = remoteAppController, agentId = req.agentId] in
                do {
                    try await controller.interrupt(agentId: agentId)
                } catch {
                    let reason = String(describing: error)
                    await MainActor.run {
                        self?.sendSystemMessage(agentId: agentId, text: "interrupt failed: \(reason)")
                    }
                }
            }
        case .targetSelectionRequest(let req):
            guard canAcceptInput(agentId: req.agentId) else { return }
            Task { [weak self, controller = remoteAppController, agentId = req.agentId, targetId = req.targetId] in
                do {
                    try await controller.selectTarget(agentId: agentId, targetId: targetId)
                } catch {
                    let reason = String(describing: error)
                    await MainActor.run {
                        self?.sendSystemMessage(agentId: agentId, text: "switch failed: \(reason)")
                    }
                }
            }
        case .targetRenameRequest(let req):
            guard canAcceptInput(agentId: req.agentId) else { return }
            Task { [weak self, controller = remoteAppController, req] in
                do {
                    try await controller.renameTarget(req)
                } catch {
                    let reason = String(describing: error)
                    await MainActor.run {
                        self?.sendSystemMessage(agentId: req.agentId, text: "rename failed: \(reason)")
                    }
                }
            }
        case .agentRuntimeSettingsUpdate(let update):
            guard canAcceptInput(agentId: update.agentId) else { return }
            Task { [weak self, controller = remoteAppController, update] in
                do {
                    try await controller.updateRuntimeSettings(update)
                } catch {
                    let reason = String(describing: error)
                    await MainActor.run {
                        self?.sendSystemMessage(agentId: update.agentId, text: "settings failed: \(reason)")
                    }
                }
            }
        case .inputRequestResponse(let response):
            guard canAcceptInput(agentId: response.agentId) else { return }
            Task { [weak self, controller = remoteAppController, response] in
                do {
                    try await controller.respondToInputRequest(response)
                } catch {
                    let reason = String(describing: error)
                    await MainActor.run {
                        self?.sendSystemMessage(agentId: response.agentId, text: "choice not sent: \(reason)")
                    }
                }
            }
        case .screenPointerInput(let input):
            guard canAcceptInput(agentId: input.agentId) else { return }
            Task { [weak self, controller = remoteAppController, input] in
                do {
                    try await controller.performScreenPointerInput(input)
                } catch {
                    let reason = String(describing: error)
                    await MainActor.run {
                        self?.sendSystemMessage(agentId: input.agentId, text: "tap failed: \(reason)")
                    }
                }
            }
        case .readOnlyModeUpdate(let update):
            readOnlyMode = update.readOnly
            autoLock.setReadOnly(update.readOnly)
        case .heartbeatPing:
            let pong = DataChannelMessage(body: .heartbeatPong(HeartbeatPong()))
            try? peer.send(pong)
        case .gridLayoutUpdate(let update):
            // Deprecated compatibility message. The Mac is still the source of
            // truth and the visible model is now remote apps, not grid cells.
            _ = update
        default:
            break
        }
    }

    private func sendInputToRemoteApp(
        agentId: AgentID,
        text: String,
        submit: Bool,
        failureLabel: String
    ) {
        guard canAcceptInput(agentId: agentId) else { return }

        Task { [weak self, controller = remoteAppController, agentId, text, submit, failureLabel] in
            do {
                try await controller.sendInput(agentId: agentId, text: text, submit: submit)
            } catch {
                let reason = String(describing: error)
                await MainActor.run {
                    self?.sendSystemMessage(agentId: agentId, text: "\(failureLabel) not sent: \(reason)")
                }
            }
        }
    }

    private func canAcceptInput(agentId: AgentID) -> Bool {
        if readOnlyMode || autoLock.isReadOnly {
            sendSystemMessage(agentId: agentId, text: "input blocked: read-only mode is on")
            return false
        }
        if autoLock.isLocked {
            sendSystemMessage(agentId: agentId, text: "input blocked: Glasstunnel is locked")
            return false
        }
        return true
    }

    private func handleImageAttachment(_ input: ImageAttachmentInput) async {
        do {
            let fileURL = try persistImageAttachment(input)
            let prompt = attachmentPrompt(userText: input.text, fileURL: fileURL)
            try await remoteAppController.sendInput(
                agentId: input.agentId,
                text: prompt,
                submit: input.submitOnSend
            )
        } catch {
            sendSystemMessage(agentId: input.agentId, text: "image upload failed: \(error.localizedDescription)")
        }
    }

    private func handleImageAttachmentChunk(_ chunk: ImageAttachmentChunk) async {
        do {
            cleanupStaleImageTransfers()
            if let input = try receiveImageAttachmentChunk(chunk) {
                await handleImageAttachment(input)
            }
        } catch {
            imageTransfers.removeValue(forKey: chunk.transferId)
            sendSystemMessage(agentId: chunk.agentId, text: "image upload failed: \(error.localizedDescription)")
        }
    }

    private func handleFileAttachmentChunk(_ chunk: FileAttachmentChunk) async {
        do {
            cleanupStaleFileAttachmentBatches()
            if let batch = try receiveFileAttachmentChunk(chunk) {
                let prompt = attachmentPrompt(userText: batch.text, fileURLs: batch.fileURLs)
                try await remoteAppController.sendInput(
                    agentId: batch.agentId,
                    text: prompt,
                    submit: batch.submitOnSend
                )
            }
        } catch {
            fileAttachmentBatches.removeValue(forKey: chunk.batchId)
            sendSystemMessage(agentId: chunk.agentId, text: "file upload failed: \(error.localizedDescription)")
        }
    }

    private func receiveImageAttachmentChunk(_ chunk: ImageAttachmentChunk) throws -> ImageAttachmentInput? {
        guard chunk.totalBytes > 0 else {
            throw AttachmentError.invalidChunk("missing total size")
        }
        guard chunk.totalBytes <= Self.maxAttachmentBytes else {
            throw AttachmentError.tooLarge(limit: Self.maxAttachmentBytes)
        }
        guard chunk.chunkCount > 0, chunk.chunkCount <= Self.maxAttachmentChunks else {
            throw AttachmentError.invalidChunk("invalid chunk count")
        }
        guard chunk.chunkIndex >= 0, chunk.chunkIndex < chunk.chunkCount else {
            throw AttachmentError.invalidChunk("invalid chunk index")
        }
        guard !chunk.bytes.isEmpty else {
            throw AttachmentError.invalidChunk("empty chunk")
        }

        var transfer = imageTransfers[chunk.transferId] ?? PendingImageTransfer(
            transferId: chunk.transferId,
            agentId: chunk.agentId,
            text: chunk.text,
            filename: chunk.filename,
            mimeType: chunk.mimeType,
            totalBytes: chunk.totalBytes,
            chunkCount: chunk.chunkCount,
            submitOnSend: chunk.submitOnSend
        )

        guard transfer.matches(chunk) else {
            throw AttachmentError.invalidChunk("inconsistent transfer metadata")
        }

        transfer.chunks[chunk.chunkIndex] = chunk.bytes
        guard transfer.receivedBytes <= transfer.totalBytes else {
            throw AttachmentError.invalidChunk("received too many bytes")
        }

        imageTransfers[chunk.transferId] = transfer
        guard transfer.isComplete else { return nil }

        var bytes = Data()
        bytes.reserveCapacity(transfer.totalBytes)
        for index in 0..<transfer.chunkCount {
            guard let piece = transfer.chunks[index] else {
                return nil
            }
            bytes.append(piece)
        }

        guard bytes.count == transfer.totalBytes else {
            throw AttachmentError.invalidChunk("assembled size mismatch")
        }

        imageTransfers.removeValue(forKey: chunk.transferId)
        return ImageAttachmentInput(
            agentId: transfer.agentId,
            text: transfer.text,
            filename: transfer.filename,
            mimeType: transfer.mimeType,
            bytes: bytes,
            submitOnSend: transfer.submitOnSend
        )
    }

    private func receiveFileAttachmentChunk(_ chunk: FileAttachmentChunk) throws -> FileAttachmentBatchInput? {
        guard chunk.totalBytes > 0 else {
            throw AttachmentError.invalidChunk("missing total size")
        }
        guard chunk.totalBytes <= Self.maxAttachmentBytes else {
            throw AttachmentError.tooLarge(limit: Self.maxAttachmentBytes)
        }
        guard chunk.fileCount > 0, chunk.fileCount <= Self.maxAttachmentFiles else {
            throw AttachmentError.invalidChunk("invalid file count")
        }
        guard chunk.fileIndex >= 0, chunk.fileIndex < chunk.fileCount else {
            throw AttachmentError.invalidChunk("invalid file index")
        }
        guard chunk.chunkCount > 0, chunk.chunkCount <= Self.maxAttachmentChunks else {
            throw AttachmentError.invalidChunk("invalid chunk count")
        }
        guard chunk.chunkIndex >= 0, chunk.chunkIndex < chunk.chunkCount else {
            throw AttachmentError.invalidChunk("invalid chunk index")
        }
        guard !chunk.bytes.isEmpty else {
            throw AttachmentError.invalidChunk("empty chunk")
        }

        var batch = fileAttachmentBatches[chunk.batchId] ?? PendingFileAttachmentBatch(
            batchId: chunk.batchId,
            agentId: chunk.agentId,
            text: chunk.text,
            fileCount: chunk.fileCount,
            submitOnSend: chunk.submitOnSend
        )
        guard batch.matches(chunk) else {
            throw AttachmentError.invalidChunk("inconsistent batch metadata")
        }

        var transfer = batch.transfers[chunk.fileIndex] ?? PendingFileTransfer(
            transferId: chunk.transferId,
            fileIndex: chunk.fileIndex,
            filename: chunk.filename,
            mimeType: chunk.mimeType,
            totalBytes: chunk.totalBytes,
            chunkCount: chunk.chunkCount
        )
        guard transfer.matches(chunk) else {
            throw AttachmentError.invalidChunk("inconsistent file metadata")
        }
        guard batch.declaredBytes(replacing: transfer) <= Self.maxAttachmentBatchBytes else {
            throw AttachmentError.batchTooLarge(limit: Self.maxAttachmentBatchBytes)
        }

        transfer.chunks[chunk.chunkIndex] = chunk.bytes
        guard transfer.receivedBytes <= transfer.totalBytes else {
            throw AttachmentError.invalidChunk("received too many bytes")
        }

        if transfer.isComplete, batch.fileURLs[chunk.fileIndex] == nil {
            let bytes = try assembleFileTransfer(transfer)
            let fileURL = try persistAttachment(
                filename: transfer.filename,
                mimeType: transfer.mimeType,
                bytes: bytes
            )
            batch.fileURLs[chunk.fileIndex] = fileURL
        }

        batch.transfers[chunk.fileIndex] = transfer
        fileAttachmentBatches[chunk.batchId] = batch
        guard batch.isComplete else { return nil }

        let urls = (0..<batch.fileCount).compactMap { batch.fileURLs[$0] }
        guard urls.count == batch.fileCount else { return nil }

        fileAttachmentBatches.removeValue(forKey: chunk.batchId)
        return FileAttachmentBatchInput(
            agentId: batch.agentId,
            text: batch.text,
            fileURLs: urls,
            submitOnSend: batch.submitOnSend
        )
    }

    private func assembleFileTransfer(_ transfer: PendingFileTransfer) throws -> Data {
        var bytes = Data()
        bytes.reserveCapacity(transfer.totalBytes)
        for index in 0..<transfer.chunkCount {
            guard let piece = transfer.chunks[index] else {
                throw AttachmentError.invalidChunk("missing chunk")
            }
            bytes.append(piece)
        }

        guard bytes.count == transfer.totalBytes else {
            throw AttachmentError.invalidChunk("assembled size mismatch")
        }
        return bytes
    }

    private func cleanupStaleImageTransfers() {
        let cutoff = Date().addingTimeInterval(-Self.attachmentTransferTTL)
        imageTransfers = imageTransfers.filter { _, transfer in
            transfer.createdAt >= cutoff
        }
    }

    private func cleanupStaleFileAttachmentBatches() {
        let cutoff = Date().addingTimeInterval(-Self.attachmentTransferTTL)
        fileAttachmentBatches = fileAttachmentBatches.filter { _, batch in
            batch.createdAt >= cutoff
        }
    }

    private func persistImageAttachment(_ input: ImageAttachmentInput) throws -> URL {
        return try persistAttachment(
            filename: input.filename,
            mimeType: input.mimeType,
            bytes: input.bytes
        )
    }

    private func persistAttachment(filename: String, mimeType: String, bytes: Data) throws -> URL {
        guard !bytes.isEmpty else { throw AttachmentError.emptyPayload }
        if bytes.count > Self.maxAttachmentBytes {
            throw AttachmentError.tooLarge(limit: Self.maxAttachmentBytes)
        }

        let fm = FileManager.default
        let base = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("Glasstunnel", isDirectory: true)
            .appendingPathComponent("Uploads", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let ext = fileExtension(mimeType: mimeType, filename: filename)
        let stem = sanitizedStem(for: filename)
        let timestamp = Self.attachmentTimestampFormatter.string(from: Date())
        let nonce = UUID().uuidString.prefix(8).lowercased()
        let fileURL = directory.appendingPathComponent("\(timestamp)-\(stem)-\(nonce).\(ext)")
        try bytes.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func attachmentPrompt(userText: String, fileURL: URL) -> String {
        return attachmentPrompt(userText: userText, fileURLs: [fileURL])
    }

    private func attachmentPrompt(userText: String, fileURLs: [URL]) -> String {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let note: String
        if fileURLs.count == 1, let location = fileURLs.first?.path {
            note = "Attached file on this Mac: \(location)"
        } else {
            let locations = fileURLs.map { "- \($0.path)" }.joined(separator: "\n")
            note = "Attached files on this Mac:\n\(locations)"
        }
        if trimmed.isEmpty {
            return fileURLs.count == 1
                ? "Please inspect this uploaded file.\n\(note)"
                : "Please inspect these uploaded files.\n\(note)"
        }
        return "\(trimmed)\n\n\(note)"
    }

    private func sendSystemMessage(agentId: AgentID, text: String) {
        let message = AgentChatMessage(
            messageId: "\(agentId)-system-\(Int(Date().timeIntervalSince1970 * 1000))",
            role: .system,
            text: text
        )
        try? peer.send(DataChannelMessage(body: .agentChatMessage(message)))
    }

    private func fileExtension(mimeType: String, filename: String) -> String {
        let raw = URL(fileURLWithPath: filename).pathExtension.lowercased()
        let filtered = String(raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.prefix(12))
        if !filtered.isEmpty {
            return filtered
        }

        switch mimeType.lowercased() {
        case "application/gzip": return "gz"
        case "application/json": return "json"
        case "application/jsonl": return "jsonl"
        case "application/msword": return "doc"
        case "application/pdf": return "pdf"
        case "application/postscript": return "ai"
        case "application/rtf": return "rtf"
        case "application/vnd.apple.keynote": return "key"
        case "application/vnd.apple.numbers": return "numbers"
        case "application/vnd.apple.pages": return "pages"
        case "application/vnd.ms-excel": return "xls"
        case "application/vnd.ms-powerpoint": return "ppt"
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation": return "pptx"
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": return "xlsx"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": return "docx"
        case "application/x-tar": return "tar"
        case "application/xml": return "xml"
        case "application/yaml": return "yaml"
        case "application/zip": return "zip"
        case "audio/aiff": return "aiff"
        case "audio/mpeg": return "mp3"
        case "audio/mp4": return "m4a"
        case "audio/wav": return "wav"
        case "image/bmp": return "bmp"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/svg+xml": return "svg"
        case "text/css": return "css"
        case "text/csv": return "csv"
        case "text/html": return "html"
        case "text/javascript": return "js"
        case "text/markdown": return "md"
        case "text/plain": return "txt"
        case "text/typescript": return "ts"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "video/webm": return "webm"
        case "video/x-msvideo": return "avi"
        default:
            return "bin"
        }
    }

    private func sanitizedStem(for filename: String) -> String {
        let raw = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let filtered = raw.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                return Character(scalar)
            }
            return "-"
        }
        let collapsed = String(filtered)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return collapsed.isEmpty ? "upload" : String(collapsed.prefix(48))
    }

    private enum AttachmentError: LocalizedError {
        case emptyPayload
        case tooLarge(limit: Int)
        case batchTooLarge(limit: Int)
        case invalidChunk(String)

        var errorDescription: String? {
            switch self {
            case .emptyPayload:
                return "the selected file was empty"
            case .tooLarge(let limit):
                return "the selected file exceeds the \(limit / (1024 * 1024)) MB limit"
            case .batchTooLarge(let limit):
                return "the selected files exceed the \(limit / (1024 * 1024)) MB total limit"
            case .invalidChunk(let reason):
                return "the file transfer was invalid: \(reason)"
            }
        }
    }

    private static let maxAttachmentBytes = 25 * 1024 * 1024
    private static let maxAttachmentBatchBytes = 100 * 1024 * 1024
    private static let maxAttachmentFiles = 20
    private static let maxAttachmentChunks = 1024
    private static let attachmentTransferTTL: TimeInterval = 600
    private static let attachmentTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private struct PendingImageTransfer {
        let transferId: String
        let agentId: AgentID
        let text: String
        let filename: String
        let mimeType: String
        let totalBytes: Int
        let chunkCount: Int
        let submitOnSend: Bool
        let createdAt = Date()
        var chunks: [Int: Data] = [:]

        var receivedBytes: Int {
            chunks.values.reduce(0) { $0 + $1.count }
        }

        var isComplete: Bool {
            chunks.count == chunkCount
        }

        func matches(_ chunk: ImageAttachmentChunk) -> Bool {
            transferId == chunk.transferId &&
                agentId == chunk.agentId &&
                text == chunk.text &&
                filename == chunk.filename &&
                mimeType == chunk.mimeType &&
                totalBytes == chunk.totalBytes &&
                chunkCount == chunk.chunkCount &&
                submitOnSend == chunk.submitOnSend
        }
    }

    private struct FileAttachmentBatchInput {
        let agentId: AgentID
        let text: String
        let fileURLs: [URL]
        let submitOnSend: Bool
    }

    private struct PendingFileAttachmentBatch {
        let batchId: String
        let agentId: AgentID
        let text: String
        let fileCount: Int
        let submitOnSend: Bool
        let createdAt = Date()
        var transfers: [Int: PendingFileTransfer] = [:]
        var fileURLs: [Int: URL] = [:]

        var isComplete: Bool {
            fileURLs.count == fileCount
        }

        func declaredBytes(replacing transfer: PendingFileTransfer) -> Int {
            transfers.reduce(transfer.totalBytes) { total, item in
                let (fileIndex, existing) = item
                return fileIndex == transfer.fileIndex ? total : total + existing.totalBytes
            }
        }

        func matches(_ chunk: FileAttachmentChunk) -> Bool {
            batchId == chunk.batchId &&
                agentId == chunk.agentId &&
                text == chunk.text &&
                fileCount == chunk.fileCount &&
                submitOnSend == chunk.submitOnSend
        }
    }

    private struct PendingFileTransfer {
        let transferId: String
        let fileIndex: Int
        let filename: String
        let mimeType: String
        let totalBytes: Int
        let chunkCount: Int
        var chunks: [Int: Data] = [:]

        var receivedBytes: Int {
            chunks.values.reduce(0) { $0 + $1.count }
        }

        var isComplete: Bool {
            chunks.count == chunkCount
        }

        func matches(_ chunk: FileAttachmentChunk) -> Bool {
            transferId == chunk.transferId &&
                fileIndex == chunk.fileIndex &&
                filename == chunk.filename &&
                mimeType == chunk.mimeType &&
                totalBytes == chunk.totalBytes &&
                chunkCount == chunk.chunkCount
        }
    }

    // MARK: - Capture

    #if os(macOS)
    private func desiredVideoApps(from remoteApps: [RemoteApp]) -> [AgentID: RemoteApp] {
        remoteApps.reduce(into: [:]) { result, app in
            if app.enabled && app.available && app.hasVideo {
                result[app.agentId] = app
            }
        }
    }

    private func captureReconciler(for agentID: AgentID) -> AsyncLatestStateReconciler<RemoteApp?> {
        if let reconciler = captureReconcilers[agentID] {
            return reconciler
        }
        let reconciler = AsyncLatestStateReconciler<RemoteApp?>(initialValue: nil) { [weak self] app in
            await self?.reconcileCapture(agentID: agentID, desiredApp: app)
        }
        captureReconcilers[agentID] = reconciler
        return reconciler
    }

    private func reconcileCapture(agentID: AgentID, desiredApp: RemoteApp?) async {
        guard !isStopping, let desiredApp else {
            await stopCapture(agentId: agentID)
            return
        }
        await startCapture(for: desiredApp)
    }

    private func isCaptureDesired(_ app: RemoteApp) -> Bool {
        guard !isStopping else { return false }
        return currentRemoteApps.contains { current in
            current.agentId == app.agentId && current.enabled && current.available && current.hasVideo
        }
    }

    private func startCapture(for app: RemoteApp) async {
        guard captures[app.agentId] == nil else { return }

        if app.remoteAppId == "screen" || app.agentId == "screen" {
            let source = peer.videoSource()
            let trackID = peer.addVideoTrack(agentID: app.agentId, source: source)
            let binding = DisplayCaptureBinding(agentID: app.agentId, source: source, trackID: trackID) { [weak self] state in
                self?.handleCaptureState(state, app: app)
            }
            captures[app.agentId] = binding
            publishCaptureState(app: app, status: .working, detail: captureStartingDetail(for: app), text: captureStartingMessage(for: app))
            do {
                try await binding.start()
            } catch {
                guard captures[app.agentId] === binding else { return }
                captures.removeValue(forKey: app.agentId)
                peer.removeVideoTrack(agentID: app.agentId)
                if isCaptureDesired(app) {
                    publishCaptureFailure(app: app, reason: error.localizedDescription)
                }
            }
            return
        }
        guard let windowID = await resolveWindowID(for: app) else {
            publishCaptureFailure(app: app, reason: "The selected window is no longer available.")
            return
        }
        let source = peer.videoSource()
        let trackID = peer.addVideoTrack(agentID: app.agentId, source: source)
        let binding = WindowCaptureBinding(agentID: app.agentId, windowID: windowID, source: source, trackID: trackID) { [weak self] state in
            self?.handleCaptureState(state, app: app)
        }
        captures[app.agentId] = binding
        publishCaptureState(app: app, status: .working, detail: captureStartingDetail(for: app), text: captureStartingMessage(for: app))
        do {
            try await binding.start()
        } catch {
            guard captures[app.agentId] === binding else { return }
            captures.removeValue(forKey: app.agentId)
            peer.removeVideoTrack(agentID: app.agentId)
            if isCaptureDesired(app) {
                publishCaptureFailure(app: app, reason: error.localizedDescription)
            }
        }
    }

    private func stopCapture(agentId: AgentID) async {
        guard let binding = captures.removeValue(forKey: agentId) else { return }
        peer.removeVideoTrack(agentID: agentId)
        await binding.stop()
    }

    private func resolveWindowID(for app: RemoteApp) async -> CGWindowID? {
        let all = (try? await WindowCatalog.refresh()) ?? []
        if let match = all.first(where: {
            $0.applicationBundleID == app.applicationBundleId && $0.title == app.windowTitle
        }) {
            return match.windowID
        }
        if let match = all.first(where: { $0.applicationBundleID == app.applicationBundleId }) {
            return match.windowID
        }
        return nil
    }

    private func handleCaptureState(_ state: WindowCapture.State, app: RemoteApp) {
        guard captures[app.agentId] != nil, isCaptureDesired(app) else { return }
        switch state {
        case .idle:
            break
        case .starting:
            publishCaptureState(app: app, status: .working, detail: captureStartingDetail(for: app), text: captureStartingMessage(for: app))
        case .running:
            publishCaptureState(app: app, status: .idle, detail: captureReadyDetail(for: app), text: captureReadyMessage(for: app))
        case .stopping:
            break
        case .error(let reason):
            publishCaptureFailure(app: app, reason: reason)
        }
    }

    private func publishCaptureState(app: RemoteApp, status: AgentStatus, detail: String, text: String) {
        remoteAppController.publishRemoteAppStatus(
            remoteAppId: app.remoteAppId,
            status: status,
            detail: detail,
            text: text
        )
    }

    private func publishCaptureFailure(app: RemoteApp, reason: String) {
        let cleanReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = cleanReason.isEmpty ? "" : " \(cleanReason)"
        let text: String
        let detail: String
        if app.remoteAppId == "screen" || app.agentId == "screen" {
            detail = "Screen unavailable"
            text = "Could not start Mac Screen. Allow Screen Recording for Glasstunnel in System Settings, then retry screen.\(suffix)"
        } else {
            detail = "Video unavailable"
            text = "Could not start \(app.displayName) video.\(suffix)"
        }
        publishCaptureState(app: app, status: .error, detail: detail, text: text)
    }

    private func captureStartingDetail(for app: RemoteApp) -> String {
        app.remoteAppId == "screen" || app.agentId == "screen" ? "Starting screen stream" : "Starting video"
    }

    private func captureStartingMessage(for app: RemoteApp) -> String {
        app.remoteAppId == "screen" || app.agentId == "screen"
            ? "Starting secure Mac Screen stream."
            : "Starting \(app.displayName) video stream."
    }

    private func captureReadyDetail(for app: RemoteApp) -> String {
        app.remoteAppId == "screen" || app.agentId == "screen" ? "Screen streaming" : "Video streaming"
    }

    private func captureReadyMessage(for app: RemoteApp) -> String {
        app.remoteAppId == "screen" || app.agentId == "screen"
            ? "Mac Screen is streaming."
            : "\(app.displayName) video is streaming."
    }
    #endif

    private func sendHello(deviceLabel: String) {
        let hello = Hello(
            hostVersion: GlasstunnelProtocol.version,
            hostOsVersion: hostOSVersion(),
            hostDeviceLabel: deviceLabel,
            supportedAdapters: AdapterKind.allCases
                .filter { $0 != .unspecified }
                .map { $0.displayName },
            currentLayout: currentLayout,
            remoteApps: currentRemoteApps
        )
        try? peer.send(DataChannelMessage(body: .hello(hello)))
    }

    private func hostOSVersion() -> String {
        #if os(macOS)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #else
        return "unknown"
        #endif
    }
}

#if os(macOS)
@MainActor
private protocol VideoCaptureBinding: AnyObject {
    var agentID: AgentID { get }
    var trackID: String { get }
    func start() async throws
    func stop() async
}

/// Bridges a `WindowCapture` to a `RTCVideoSource` by converting captured
/// CMSampleBuffers into RTCVideoFrames.
@MainActor
final class WindowCaptureBinding: VideoCaptureBinding {
    let agentID: AgentID
    let windowID: CGWindowID
    let source: RTCVideoSource
    let trackID: String
    private var capture: WindowCapture
    private let onState: (WindowCapture.State) -> Void
    private let downsampler = FrameDownsampler(targetMaxDimension: 1280)

    init(agentID: AgentID, windowID: CGWindowID, source: RTCVideoSource, trackID: String, onState: @escaping (WindowCapture.State) -> Void) {
        self.agentID = agentID
        self.windowID = windowID
        self.source = source
        self.trackID = trackID
        self.capture = WindowCapture(windowID: windowID)
        self.onState = onState
    }

    func start() async throws {
        capture.onState = { [onState] state in
            Task { @MainActor in onState(state) }
        }
        let downsampler = downsampler
        capture.onFrame = { [weak source, downsampler] sampleBuffer in
            guard let source else { return }
            guard let frame = makeVideoFrame(from: sampleBuffer, downsampler: downsampler) else { return }
            source.capturer(RTCVideoCapturer(delegate: source), didCapture: frame)
        }
        try await capture.start()
    }

    func stop() async {
        capture.onFrame = nil
        capture.onState = nil
        await capture.stop()
    }
}

/// Bridges a full-display `DisplayCapture` to a `RTCVideoSource`.
@MainActor
final class DisplayCaptureBinding: VideoCaptureBinding {
    let agentID: AgentID
    let source: RTCVideoSource
    let trackID: String
    private var capture: DisplayCapture
    private let onState: (WindowCapture.State) -> Void
    private let downsampler = FrameDownsampler(targetMaxDimension: 1280)

    init(agentID: AgentID, source: RTCVideoSource, trackID: String, onState: @escaping (WindowCapture.State) -> Void) {
        self.agentID = agentID
        self.source = source
        self.trackID = trackID
        self.capture = DisplayCapture()
        self.onState = onState
    }

    func start() async throws {
        capture.onState = { [onState] state in
            Task { @MainActor in onState(state) }
        }
        let downsampler = downsampler
        capture.onFrame = { [weak source, downsampler] sampleBuffer in
            guard let source else { return }
            guard let frame = makeVideoFrame(from: sampleBuffer, downsampler: downsampler) else { return }
            source.capturer(RTCVideoCapturer(delegate: source), didCapture: frame)
        }
        try await capture.start()
    }

    func stop() async {
        capture.onFrame = nil
        capture.onState = nil
        await capture.stop()
    }
}

private func makeVideoFrame(from sampleBuffer: CMSampleBuffer, downsampler: FrameDownsampler) -> RTCVideoFrame? {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
    let videoBuffer = downsampler.downsample(pixelBuffer) ?? pixelBuffer
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let timestampNs = Int64(CMTimeGetSeconds(timestamp) * Double(NSEC_PER_SEC))
    return RTCVideoFrame(
        buffer: RTCCVPixelBuffer(pixelBuffer: videoBuffer),
        rotation: ._0,
        timeStampNs: timestampNs
    )
}
#endif

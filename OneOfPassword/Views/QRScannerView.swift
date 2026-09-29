//
//  QRScannerView.swift
//  OneOfPassword
//
//  二维码扫描视图（摄像头 / 截屏 / 选图）
//

import SwiftUI
import AVFoundation
import Vision
import AppKit

// MARK: - 主视图

struct QRScannerView: View {
    @Environment(\.dismiss) var dismiss
    /// 扫描成功后回调 TOTPConfig（用于 ItemDetailView 回填）
    var onParsed: ((TOTPConfig) -> Void)? = nil

    @State private var parsedConfig: TOTPConfig?
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var isCapturing = false

    // 权限引导：哪个权限被拒了、要不要弹框
    @State private var showPermissionAlert = false
    @State private var alertPermission: AppPermission = .screenRecording

    private let totpGenerator = TOTPGenerator.shared

    var body: some View {
        NavigationStack {
            VStack {
                if let config = parsedConfig {
                    successView(config: config)
                } else {
                    optionsView
                }
            }
            .navigationTitle("添加验证码")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("未能识别二维码", isPresented: $showingError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .alert("需要「\(alertPermission.title)」权限", isPresented: $showPermissionAlert) {
                // 优先送用户去应用内的「设置 → 系统权限」：那里能看到完整的用途说明、
                // 当前状态和诊断日志，而不是一头扎进系统设置里找不到北。
                Button("去应用设置") {
                    dismiss()
                    NotificationCenter.default.post(name: .openAppPermissions, object: nil)
                }
                Button("打开系统设置") {
                    alertPermission.openSystemSettings()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("「\(alertPermission.usedBy)」需要「\(alertPermission.title)」权限。\n"
                     + "可在「设置 → 系统权限」中查看状态，或直接前往「系统设置 → 隐私与安全性 → \(alertPermission.title)」勾选 OneOfPassword。")
            }
            .sheet(isPresented: $showingCamera) {
                CameraQRView { payload in
                    showingCamera = false
                    handlePayload(payload)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    // MARK: - 三入口选项页

    private var optionsView: some View {
        VStack(spacing: 24) {
            Text("选择添加方式")
                .font(.title2)
                .fontWeight(.semibold)

            HStack(spacing: 20) {
                OptionCard(
                    icon: "camera.fill",
                    title: "摄像头扫描",
                    description: "对准二维码自动识别"
                ) {
                    showCameraSheet()
                }

                OptionCard(
                    icon: "rectangle.dashed.badge.record",
                    title: "截取屏幕",
                    description: "框选屏幕上的二维码"
                ) {
                    Task { await captureScreen() }
                }

                OptionCard(
                    icon: "photo.badge.plus",
                    title: "选择图片",
                    description: "从文件选择二维码图片"
                ) {
                    pickImage()
                }
            }
            .padding()

            if isCapturing {
                ProgressView("正在识别…")
                    .padding()
            }
        }
        .padding()
    }

    // MARK: - 识别成功页

    private func successView(config: TOTPConfig) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)

            Text("识别成功")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 12) {
                if let issuer = config.issuer {
                    InfoRow(label: "发行者", value: issuer)
                }
                InfoRow(label: "账户",      value: config.accountName)
                InfoRow(label: "验证码位数", value: "\(config.digits)")
                InfoRow(label: "有效期",    value: "\(config.period) 秒")
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal)

            HStack(spacing: 12) {
                Button("重新扫描") {
                    parsedConfig = nil
                }
                .buttonStyle(.secondary())

                Button {
                    onParsed?(config)
                    dismiss()
                } label: {
                    Label("使用", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.primary())
            }
        }
        .padding()
    }

    // MARK: - 摄像头

    @State private var showingCamera = false

    private func showCameraSheet() {
        // 先过权限：摄像头未授权时不再「打开 sheet 看到一片黑」，
        // 而是就地弹引导（或在系统弹框里当场授权）。
        AppPermission.requestCamera { granted in
            PermissionCenter.shared.refresh()
            if granted {
                showingCamera = true
            } else {
                alertPermission = .camera
                showPermissionAlert = true
            }
        }
    }

    // MARK: - 截屏识别

    private func captureScreen() async {
        // 屏幕录制权限：统一走 `AppPermission` 这一份真相（与「设置 → 系统权限」同源）
        switch AppPermission.screenRecording.status {
        case .authorized:
            break
        default:
            // 请求后系统弹框可能同步返回 false（授权异步生效），所以不采信返回值，
            // 直接提示引导 —— 用户去系统设置勾选后回来即可用。
            AppPermission.screenRecording.request()
            PermissionCenter.shared.refresh()
            if !AppPermission.screenRecording.status.isAuthorized {
                alertPermission = .screenRecording
                showPermissionAlert = true
            }
            return
        }

        isCapturing = true
        defer { isCapturing = false }

        NSApp.keyWindow?.miniaturize(nil)
        try? await Task.sleep(for: .milliseconds(400))

        do {
            let image = try await ScreenshotPicker.capture()
            NSApp.keyWindow?.deminiaturize(nil)
            let payload = try await QRCodeDetector.detect(in: image)
            handlePayload(payload)
        } catch QRCodeDetectorError.noQRCodeFound {
            NSApp.keyWindow?.deminiaturize(nil)
            errorMessage = "所选区域内未找到二维码，请重试。"
            showingError = true
        } catch is CancellationError {
            NSApp.keyWindow?.deminiaturize(nil)
            // 用户主动取消，静默处理
        } catch {
            NSApp.keyWindow?.deminiaturize(nil)
            // 走到这里多半仍是权限问题（screencapture 子进程被 TCC 拦下），
            // 统一按屏幕录制权限引导；`alertPermission` 必须显式设置，否则会沿用上一次的值。
            alertPermission = .screenRecording
            showPermissionAlert = true
        }
    }

    // MARK: - 选择图片

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .bmp, .gif, .tiff, .heic]
        panel.allowsMultipleSelection = false
        panel.message = "选择包含二维码的图片"
        panel.prompt = "识别"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isCapturing = true
        Task {
            defer { isCapturing = false }
            do {
                guard let nsImage = NSImage(contentsOf: url),
                      let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    errorMessage = "无法读取所选图片。"
                    showingError = true
                    return
                }
                let payload = try await QRCodeDetector.detect(in: cgImage)
                handlePayload(payload)
            } catch QRCodeDetectorError.noQRCodeFound {
                errorMessage = "图片中未找到二维码。"
                showingError = true
            } catch {
                errorMessage = "图片读取失败：\(error.localizedDescription)"
                showingError = true
            }
        }
    }

    // MARK: - 公共处理

    private func handlePayload(_ payload: String) {
        if let config = totpGenerator.parseOTPAuthURL(payload) {
            parsedConfig = config
        } else {
            errorMessage = "识别到内容但不是有效的 OTP 二维码：\n\(payload)"
            showingError = true
        }
    }
}

// MARK: - 选项卡片组件

private struct OptionCard: View {
    let icon: String
    let title: String
    let description: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 36))
                    .foregroundColor(.accentColor)

                Text(title)
                    .font(.headline)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 130, height: 130)
            .background(Color.gray.opacity(0.08))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - InfoRow

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

// MARK: - 截屏选区工具

enum ScreenshotPicker {
    static func capture() async throws -> CGImage {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("qr_capture_\(UUID().uuidString).png")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-s", "-x", tmpURL.path]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let nsImage = NSImage(contentsOf: tmpURL),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            try? FileManager.default.removeItem(at: tmpURL)
            throw CancellationError()
        }

        try? FileManager.default.removeItem(at: tmpURL)
        return cgImage
    }
}

// MARK: - 摄像头预览（NSViewRepresentable）

struct CameraPreviewView: NSViewRepresentable {
    let onCodeScanned: (String) -> Void
    /// 摄像头设备打不开时回调（主线程）。以前这里是静默 `return`，表现就是「一片黑、没提示」。
    var onUnavailable: (() -> Void)? = nil

    func makeNSView(context: Context) -> CameraPreview {
        let preview = CameraPreview()
        preview.delegate = context.coordinator
        preview.onSetupFailed = onUnavailable
        return preview
    }

    func updateNSView(_ nsView: CameraPreview, context: Context) {
        nsView.onSetupFailed = onUnavailable
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeScanned: onCodeScanned)
    }

    class Coordinator: NSObject, CameraPreviewDelegate {
        let onCodeScanned: (String) -> Void

        init(onCodeScanned: @escaping (String) -> Void) {
            self.onCodeScanned = onCodeScanned
        }

        func didDetectQRCode(_ code: String) {
            onCodeScanned(code)
        }
    }
}

protocol CameraPreviewDelegate: AnyObject {
    func didDetectQRCode(_ code: String)
}

class CameraPreview: NSView, AVCaptureVideoDataOutputSampleBufferDelegate {
    weak var delegate: CameraPreviewDelegate?
    /// 设备/输入不可用时回调（主线程）
    var onSetupFailed: (() -> Void)?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupCamera()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupCamera()
    }

    private func setupCamera() {
        let session = AVCaptureSession()

        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video),
              let videoInput = try? AVCaptureDeviceInput(device: videoCaptureDevice),
              session.canAddInput(videoInput) else {
            // 别静默 return（用户只会看到一片黑）。交给上层显示明确原因。
            DispatchQueue.main.async { [weak self] in
                self?.onSetupFailed?()
            }
            return
        }

        session.addInput(videoInput)

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "qr.scan.queue"))
        videoOutput.alwaysDiscardsLateVideoFrames = true

        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        self.wantsLayer = true
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = bounds
        self.layer?.addSublayer(previewLayer)

        self.captureSession = session
        self.previewLayer = previewLayer

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !hasScanned,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectBarcodesRequest { [weak self] request, _ in
            guard let self,
                  let results = request.results as? [VNBarcodeObservation],
                  let barcode = results.first(where: { $0.symbology == .qr }),
                  let payload = barcode.payloadStringValue else { return }

            self.hasScanned = true
            self.captureSession?.stopRunning()
            DispatchQueue.main.async {
                self.delegate?.didDetectQRCode(payload)
            }
        }
        request.symbologies = [.qr]

        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
    }

    deinit {
        captureSession?.stopRunning()
    }
}

// MARK: - 摄像头扫描 Sheet

struct CameraQRView: View {
    @Environment(\.dismiss) var dismiss
    let onScanned: (String) -> Void

    @ObservedObject private var center = PermissionCenter.shared
    /// 权限有、但设备打不开（没摄像头 / 被别的 App 独占）
    @State private var cameraUnavailable = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if !center.status(.camera).isAuthorized {
                    // 权限不到位时直接给引导，不要「先打开预览、再看到一片黑」
                    PermissionUnavailableView(permission: .camera)
                        .frame(height: 400)
                } else if cameraUnavailable {
                    VStack(spacing: 8) {
                        Image(systemName: "video.slash")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("未能启动摄像头")
                            .font(.headline)
                        Text("请确认本机有可用摄像头，且未被其他应用占用。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(height: 400)
                } else {
                    CameraPreviewView(
                        onCodeScanned: { payload in onScanned(payload) },
                        onUnavailable: { cameraUnavailable = true }
                    )
                    .frame(height: 400)
                    .cornerRadius(12)
                    .padding()

                    Text("请将二维码对准摄像头")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.bottom)
                }
            }
            .navigationTitle("摄像头扫描")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 480)
        .onAppear { center.beginObserving() }
        .onDisappear { center.endObserving() }
    }
}

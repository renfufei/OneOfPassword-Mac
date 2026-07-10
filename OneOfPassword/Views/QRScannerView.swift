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
    @State private var showPermissionAlert = false

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
            .alert("需要屏幕录制权限", isPresented: $showPermissionAlert) {
                Button("前往设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("截取屏幕需要「屏幕录制」权限。\n请前往「系统设置 → 隐私与安全性 → 屏幕录制」，勾选 OneOfPassword 后重试。")
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
        showingCamera = true
    }

    // MARK: - 截屏识别

    private func captureScreen() async {
        // 先检查屏幕录制权限
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            // 请求后再检查一次，仍未授权则提示引导
            if !CGPreflightScreenCaptureAccess() {
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

    func makeNSView(context: Context) -> CameraPreview {
        let preview = CameraPreview()
        preview.delegate = context.coordinator
        return preview
    }

    func updateNSView(_ nsView: CameraPreview, context: Context) {}

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
              session.canAddInput(videoInput) else { return }

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

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                CameraPreviewView { payload in
                    onScanned(payload)
                }
                .frame(height: 400)
                .cornerRadius(12)
                .padding()

                Text("请将二维码对准摄像头")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.bottom)
            }
            .navigationTitle("摄像头扫描")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 480)
    }
}

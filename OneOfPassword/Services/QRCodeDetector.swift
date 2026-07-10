//
//  QRCodeDetector.swift
//  OneOfPassword
//
//  从 CGImage 中用 Vision 识别二维码，供截图和选图功能共用。
//

import Vision
import CoreGraphics

enum QRCodeDetectorError: Error {
    case noQRCodeFound
    case invalidImage
}

struct QRCodeDetector {
    /// 从任意 CGImage 中识别第一个二维码，返回 payload 字符串。
    static func detect(in image: CGImage) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNDetectBarcodesRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let results = request.results as? [VNBarcodeObservation],
                      let barcode = results.first(where: { $0.symbology == .qr }),
                      let payload = barcode.payloadStringValue else {
                    continuation.resume(throwing: QRCodeDetectorError.noQRCodeFound)
                    return
                }
                continuation.resume(returning: payload)
            }
            request.symbologies = [.qr]

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

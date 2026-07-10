//
//  TOTPGenerator.swift
//  OneOfPassword
//
//  TOTP 验证码生成器
//

import Foundation
import CommonCrypto

struct TOTPConfig {
    var secret: String
    var issuer: String?
    var accountName: String
    var digits: Int
    var period: Int
}

class TOTPGenerator {
    static let shared = TOTPGenerator()

    private init() {}

    // MARK: - TOTP Generation

    func generateTOTP(secret: String, digits: Int = 6, period: Int = 30, counterOffset: Int = 0) -> String? {
        guard let keyData = base32Decode(secret) else {
            return nil
        }

        let counter = UInt64(Date().timeIntervalSince1970 / Double(period)) + UInt64(counterOffset)
        var bigCounter = counter.bigEndian

        let counterData = withUnsafeBytes(of: &bigCounter) { Data($0) }

        guard let hash = hmacSHA1(key: keyData, data: counterData) else {
            return nil
        }

        let offset = Int(hash[hash.count - 1] & 0x0f)

        let truncatedHash = hash.subdata(in: offset..<offset + 4)
        let value = truncatedHash.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian

        let otp = (value & 0x7fffffff) % UInt32(pow(10, Double(digits)))

        return String(format: "%0*d", digits, otp)
    }

    // MARK: - Remaining Time

    func getRemainingTime(period: Int = 30) -> Int {
        let currentTime = Date().timeIntervalSince1970
        let elapsed = Int(currentTime) % period
        return period - elapsed
    }

    // MARK: - OTP Auth URL Parsing

    func parseOTPAuthURL(_ urlString: String) -> TOTPConfig? {
        guard let url = URL(string: urlString),
              url.scheme == "otpauth",
              url.host == "totp" || url.host == "hotp" else {
            return nil
        }

        // Extract account name from path
        let path = url.path
        let accountName = String(path.dropFirst()) // Remove leading '/'

        // Parse query parameters
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return nil
        }

        var secret: String?
        var issuer: String?
        var digits = 6
        var period = 30

        for item in queryItems {
            switch item.name {
            case "secret":
                secret = item.value
            case "issuer":
                issuer = item.value
            case "digits":
                if let value = item.value, let intValue = Int(value) {
                    digits = intValue
                }
            case "period":
                if let value = item.value, let intValue = Int(value) {
                    period = intValue
                }
            default:
                break
            }
        }

        guard let validSecret = secret else {
            return nil
        }

        return TOTPConfig(
            secret: validSecret,
            issuer: issuer,
            accountName: accountName,
            digits: digits,
            period: period
        )
    }

    // MARK: - Base32 Decoding

    private func base32Decode(_ string: String) -> Data? {
        let base32Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        var bits = ""

        let cleanString = string.uppercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "=", with: "")

        for char in cleanString {
            if let index = base32Alphabet.firstIndex(of: char) {
                let value = base32Alphabet.distance(from: base32Alphabet.startIndex, to: index)
                bits += String(value, radix: 2).leftPadding(toLength: 5, withPad: "0")
            } else {
                return nil
            }
        }

        var data = Data()
        var index = bits.startIndex

        while index < bits.endIndex {
            let endIndex = bits.index(index, offsetBy: 8, limitedBy: bits.endIndex) ?? bits.endIndex
            let byteString = String(bits[index..<endIndex])

            if byteString.count == 8, let byte = UInt8(byteString, radix: 2) {
                data.append(byte)
            }

            index = endIndex
        }

        return data
    }

    // MARK: - HMAC-SHA1

    private func hmacSHA1(key: Data, data: Data) -> Data? {
        var macOut = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))

        key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1),
                       keyBytes.baseAddress, key.count,
                       dataBytes.baseAddress, data.count,
                       &macOut)
            }
        }

        return Data(macOut)
    }
}

// MARK: - String Extension

extension String {
    func leftPadding(toLength: Int, withPad character: Character) -> String {
        let stringLength = self.count
        if stringLength < toLength {
            return String(repeatElement(character, count: toLength - stringLength)) + self
        } else {
            return self
        }
    }
}

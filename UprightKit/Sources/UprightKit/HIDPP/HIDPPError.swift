import Foundation

public enum HIDPPError: Error, Equatable, Sendable, CustomStringConvertible {
    case timeout
    case transportClosed
    case sendFailed(Int32)
    case hidpp10(UInt8)
    case hidpp20(UInt8)
    case featureNotSupported(UInt16)
    case unsupportedProtocol(major: UInt8, minor: UInt8)
    case malformedResponse
    case notMXVertical(String)

    public var description: String {
        switch self {
        case .timeout:
            return "The device did not answer in time."
        case .transportClosed:
            return "The HID connection was closed."
        case .sendFailed(let code):
            return String(format: "Sending the HID report failed (IOReturn 0x%08X).", UInt32(bitPattern: code))
        case .hidpp10(let code):
            return "HID++ 1.0 error: \(Self.hidpp10Name(code)) (0x\(String(format: "%02X", code)))."
        case .hidpp20(let code):
            return "HID++ 2.0 error: \(Self.hidpp20Name(code)) (0x\(String(format: "%02X", code)))."
        case .featureNotSupported(let id):
            return "The device does not support HID++ feature 0x\(String(format: "%04X", id))."
        case .unsupportedProtocol(let major, let minor):
            return "The device speaks HID++ \(major).\(minor); HID++ 2.0 or newer is required."
        case .malformedResponse:
            return "The device sent a response that could not be decoded."
        case .notMXVertical(let name):
            return "Found “\(name)”, which is not an MX Vertical."
        }
    }

    /// True when a receiver reports that nothing is answering in a slot (empty, asleep, or off).
    public var meansDeviceUnreachable: Bool {
        switch self {
        case .timeout: return true
        case .hidpp10(let code): return [0x04, 0x08, 0x09].contains(code)
        default: return false
        }
    }

    static func hidpp10Name(_ code: UInt8) -> String {
        switch code {
        case 0x01: return "invalid sub-ID"
        case 0x02: return "invalid address"
        case 0x03: return "invalid value"
        case 0x04: return "connection failed"
        case 0x05: return "too many devices"
        case 0x06: return "already exists"
        case 0x07: return "busy"
        case 0x08: return "unknown device"
        case 0x09: return "resource error"
        case 0x0A: return "request unavailable"
        case 0x0B: return "invalid parameter value"
        case 0x0C: return "wrong PIN code"
        default: return "unknown"
        }
    }

    static func hidpp20Name(_ code: UInt8) -> String {
        switch code {
        case 0x01: return "unknown"
        case 0x02: return "invalid argument"
        case 0x03: return "out of range"
        case 0x04: return "hardware error"
        case 0x05: return "internal error"
        case 0x06: return "invalid feature index"
        case 0x07: return "invalid function"
        case 0x08: return "busy"
        case 0x09: return "unsupported"
        default: return "unknown"
        }
    }
}

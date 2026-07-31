import Foundation

public enum CaptureError: Error, CustomStringConvertible {
    case coreAudio(String, OSStatus)
    case invalidState(String)

    public var description: String {
        switch self {
        case .coreAudio(let what, let status): "\(what) failed (OSStatus \(status))"
        case .invalidState(let why): why
        }
    }
}

@discardableResult
func checkOS(_ status: OSStatus, _ what: String) throws -> OSStatus {
    guard status == noErr else { throw CaptureError.coreAudio(what, status) }
    return status
}

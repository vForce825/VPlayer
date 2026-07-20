// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

enum VTPropertyValue: Sendable, Equatable {
    case boolean(Bool)
    case string(String)
    case unsigned32(UInt32)
    case array([VTPropertyValue])
    case dictionary([String: VTPropertyValue])
    case unsupportedType

    fileprivate var propertyListObject: Any? {
        switch self {
        case let .boolean(value):
            return value ? kCFBooleanTrue : kCFBooleanFalse
        case let .string(value):
            return value as CFString
        case let .unsigned32(value):
            var storedValue = value
            return CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &storedValue)
        case let .array(values):
            var objects: [Any] = []
            for value in values {
                guard let object = value.propertyListObject else { return nil }
                objects.append(object)
            }
            return objects as CFArray
        case let .dictionary(values):
            var objects: [String: Any] = [:]
            for (key, value) in values {
                guard let object = value.propertyListObject else { return nil }
                objects[key] = object
            }
            return objects as CFDictionary
        case .unsupportedType:
            return nil
        }
    }

    fileprivate static func ownedCopy(of value: CFTypeRef?) -> VTPropertyValue? {
        guard let value else { return nil }
        let typeID = CFGetTypeID(value)
        if typeID == CFBooleanGetTypeID() {
            return .boolean(CFEqual(value, kCFBooleanTrue))
        }
        if typeID == CFStringGetTypeID(), let string = value as? String {
            return .string(String(string))
        }
        if typeID == CFNumberGetTypeID(), let number = value as? NSNumber {
            return .unsigned32(number.uint32Value)
        }
        return .unsupportedType
    }
}

struct VTSessionID: Hashable, Sendable {
    let rawValue: UInt64
}

protocol VideoToolboxSession: AnyObject, Sendable {
    var id: VTSessionID { get }
}

struct VTPropertyCopyResult: Sendable, Equatable {
    let status: OSStatus
    let value: VTPropertyValue?
}

struct VTSupportedPropertySnapshot: Sendable, Equatable {
    let status: OSStatus
    let supportedPropertyKeys: Set<String>?
}

struct VTDecodeOutput: @unchecked Sendable {
    let status: OSStatus
    let infoFlags: VTDecodeInfoFlags
    let imageBuffer: CVPixelBuffer?
    let presentationTimeStamp: CMTime
    let duration: CMTime
}

protocol VTSessionPropertyAPI: AnyObject {
    func copySupportedPropertySnapshot(
        _ session: any VideoToolboxSession
    ) -> VTSupportedPropertySnapshot
    func setProperty(
        _ session: any VideoToolboxSession,
        key: String,
        value: VTPropertyValue
    ) -> OSStatus
}

protocol VideoToolboxAPI: AnyObject, VTSessionPropertyAPI {
    func createSession(
        format: CMVideoFormatDescription,
        decoderSpecification: [String: VTPropertyValue],
        imageBufferAttributes: [String: VTPropertyValue]
    ) -> (status: OSStatus, session: (any VideoToolboxSession)?)
    func copyProperty(
        _ session: any VideoToolboxSession,
        key: String
    ) -> VTPropertyCopyResult
    func decode(
        _ session: any VideoToolboxSession,
        sampleBuffer: CMSampleBuffer,
        flags: VTDecodeFrameFlags,
        frameOptions: [String: VTPropertyValue]?,
        output: @escaping @Sendable (VTDecodeOutput) -> Void
    ) -> OSStatus
    func finishDelayedFrames(_ session: any VideoToolboxSession) -> OSStatus
    func waitForAsynchronousFrames(_ session: any VideoToolboxSession) -> OSStatus
    func invalidate(_ session: any VideoToolboxSession)
}

private final class VTSessionIDAllocator: @unchecked Sendable {
    static let shared = VTSessionIDAllocator()

    private let lock = NSLock()
    private var nextRawValue: UInt64 = 1

    func allocate() -> VTSessionID {
        lock.lock()
        defer { lock.unlock() }
        let id = VTSessionID(rawValue: nextRawValue)
        nextRawValue &+= 1
        return id
    }
}

private final class SystemVideoToolboxSession: VideoToolboxSession, @unchecked Sendable {
    let id: VTSessionID
    let rawSession: VTDecompressionSession

    init(id: VTSessionID, rawSession: VTDecompressionSession) {
        self.id = id
        self.rawSession = rawSession
    }
}

final class SystemVideoToolboxAPI: VideoToolboxAPI {
    func createSession(
        format: CMVideoFormatDescription,
        decoderSpecification: [String: VTPropertyValue],
        imageBufferAttributes: [String: VTPropertyValue]
    ) -> (status: OSStatus, session: (any VideoToolboxSession)?) {
        guard let decoderDictionary = makeDictionary(decoderSpecification),
              let imageDictionary = makeDictionary(imageBufferAttributes) else {
            return (kVTParameterErr, nil)
        }
        var rawSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: decoderDictionary,
            imageBufferAttributes: imageDictionary,
            outputCallback: nil,
            decompressionSessionOut: &rawSession
        )
        let session = rawSession.map {
            SystemVideoToolboxSession(
                id: VTSessionIDAllocator.shared.allocate(),
                rawSession: $0
            ) as any VideoToolboxSession
        }
        return (status, session)
    }

    func setProperty(
        _ session: any VideoToolboxSession,
        key: String,
        value: VTPropertyValue
    ) -> OSStatus {
        guard let session = session as? SystemVideoToolboxSession,
              let object = value.propertyListObject else {
            return kVTParameterErr
        }
        return VTSessionSetProperty(
            session.rawSession,
            key: key as CFString,
            value: object as CFTypeRef
        )
    }

    func copySupportedPropertySnapshot(
        _ session: any VideoToolboxSession
    ) -> VTSupportedPropertySnapshot {
        guard let session = session as? SystemVideoToolboxSession else {
            return VTSupportedPropertySnapshot(
                status: kVTInvalidSessionErr,
                supportedPropertyKeys: nil
            )
        }
        var copiedDictionary: CFDictionary?
        let status = VTSessionCopySupportedPropertyDictionary(
            session.rawSession,
            supportedPropertyDictionaryOut: &copiedDictionary
        )
        let copiedKeys: Set<String>? = copiedDictionary.map { dictionary in
            Set<String>((dictionary as NSDictionary).allKeys.compactMap { rawKey in
                guard let key = rawKey as? String else { return nil }
                return String(key)
            })
        }
        return VTSupportedPropertySnapshot(
            status: status,
            supportedPropertyKeys: copiedKeys
        )
    }

    func copyProperty(
        _ session: any VideoToolboxSession,
        key: String
    ) -> VTPropertyCopyResult {
        guard let session = session as? SystemVideoToolboxSession else {
            return VTPropertyCopyResult(status: kVTInvalidSessionErr, value: nil)
        }
        var copied: Unmanaged<CFTypeRef>?
        let status = withUnsafeMutablePointer(to: &copied) { pointer in
            VTSessionCopyProperty(
                session.rawSession,
                key: key as CFString,
                allocator: kCFAllocatorDefault,
                valueOut: UnsafeMutableRawPointer(pointer)
            )
        }
        let ownedValue = copied?.takeRetainedValue()
        return VTPropertyCopyResult(
            status: status,
            value: status == noErr ? VTPropertyValue.ownedCopy(of: ownedValue) : nil
        )
    }

    func decode(
        _ session: any VideoToolboxSession,
        sampleBuffer: CMSampleBuffer,
        flags: VTDecodeFrameFlags,
        frameOptions: [String: VTPropertyValue]?,
        output: @escaping @Sendable (VTDecodeOutput) -> Void
    ) -> OSStatus {
        guard let session = session as? SystemVideoToolboxSession else {
            return kVTInvalidSessionErr
        }
        let options: CFDictionary?
        if let frameOptions {
            guard let dictionary = makeDictionary(frameOptions) else { return kVTParameterErr }
            options = dictionary
        } else {
            options = nil
        }
        return VTDecompressionSessionDecodeFrame(
            session.rawSession,
            sampleBuffer: sampleBuffer,
            flags: flags,
            frameOptions: options,
            infoFlagsOut: nil
        ) { status, infoFlags, imageBuffer, presentationTimeStamp, duration in
            let ownedOutput = VTDecodeOutput(
                status: status,
                infoFlags: infoFlags,
                imageBuffer: imageBuffer,
                presentationTimeStamp: presentationTimeStamp,
                duration: duration
            )
            output(ownedOutput)
        }
    }

    func finishDelayedFrames(_ session: any VideoToolboxSession) -> OSStatus {
        guard let session = session as? SystemVideoToolboxSession else {
            return kVTInvalidSessionErr
        }
        return VTDecompressionSessionFinishDelayedFrames(session.rawSession)
    }

    func waitForAsynchronousFrames(_ session: any VideoToolboxSession) -> OSStatus {
        guard let session = session as? SystemVideoToolboxSession else {
            return kVTInvalidSessionErr
        }
        return VTDecompressionSessionWaitForAsynchronousFrames(session.rawSession)
    }

    func invalidate(_ session: any VideoToolboxSession) {
        guard let session = session as? SystemVideoToolboxSession else { return }
        VTDecompressionSessionInvalidate(session.rawSession)
    }

    private func makeDictionary(
        _ values: [String: VTPropertyValue]
    ) -> CFDictionary? {
        var objects: [String: Any] = [:]
        for (key, value) in values {
            guard let object = value.propertyListObject else { return nil }
            objects[key] = object
        }
        return objects as CFDictionary
    }
}

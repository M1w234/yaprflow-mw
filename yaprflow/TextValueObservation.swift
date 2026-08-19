import Foundation

/// UTF-16 geometry for watching an insertion in controls that expose only
/// their AXValue, not ranged Accessibility text APIs. The original field value
/// is used transiently to create this snapshot; only short boundary anchors
/// and integer offsets are retained.
struct TextValueObservation: Equatable, Sendable {
    let insertionStart: Int
    let replacedLength: Int
    let originalTotalCount: Int
    let prefixAnchor: String
    let suffixAnchor: String

    init?(
        original: String,
        selectionLocation: Int?,
        selectionLength: Int?,
        anchorLength: Int = 32
    ) {
        let totalCount = original.utf16.count
        let location: Int
        let length: Int
        if let selectionLocation,
           let selectionLength,
           selectionLocation >= 0,
           selectionLength >= 0,
           selectionLocation + selectionLength <= totalCount {
            location = selectionLocation
            length = selectionLength
        } else {
            // Some Electron/contenteditable controls expose AXValue but no
            // selection. Synthetic typing normally lands at the end. If it
            // does not, the prefix check below fails safely and learns nothing.
            location = totalCount
            length = 0
        }

        let prefixStart = max(0, location - anchorLength)
        guard let prefix = Self.slice(
            original,
            location: prefixStart,
            length: location - prefixStart
        ) else { return nil }
        let selectionEnd = location + length
        guard let suffix = Self.slice(
            original,
            location: selectionEnd,
            length: min(anchorLength, totalCount - selectionEnd)
        ) else { return nil }

        insertionStart = location
        replacedLength = length
        originalTotalCount = totalCount
        prefixAnchor = prefix
        suffixAnchor = suffix
    }

    func insertedSegment(
        in current: String,
        expectedUTF16Length: Int,
        maximumGrowth: Int = 160
    ) -> String? {
        let currentCount = current.utf16.count
        let originalTailCount = originalTotalCount - insertionStart - replacedLength
        let candidateLength = currentCount - insertionStart - originalTailCount
        guard candidateLength >= 0,
              candidateLength <= expectedUTF16Length + maximumGrowth else { return nil }

        if !prefixAnchor.isEmpty {
            let prefixLength = prefixAnchor.utf16.count
            let prefixStart = insertionStart - prefixLength
            guard prefixStart >= 0,
                  Self.slice(current, location: prefixStart, length: prefixLength)
                    == prefixAnchor else { return nil }
        }

        if !suffixAnchor.isEmpty {
            let suffixLength = suffixAnchor.utf16.count
            let suffixStart = insertionStart + candidateLength
            guard Self.slice(current, location: suffixStart, length: suffixLength)
                    == suffixAnchor else { return nil }
        }

        return Self.slice(current, location: insertionStart, length: candidateLength)
    }

    private static func slice(_ value: String, location: Int, length: Int) -> String? {
        guard location >= 0, length >= 0 else { return nil }
        let string = value as NSString
        guard location + length <= string.length else { return nil }
        return string.substring(with: NSRange(location: location, length: length))
    }
}

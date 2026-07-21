import Foundation

/// Sentence-aware request segmentation shared by speech engines that have a
/// finite useful prompt length. The caller owns engine-specific target sizes.
public enum SpeechTextChunker {
    public static func chunk(
        _ text: String,
        firstTarget: Int,
        target: Int,
        hardSplitLimit: Int
    ) -> [String] {
        precondition(firstTarget > 0 && target > 0 && hardSplitLimit > 0)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var sentences: [String] = []
        trimmed.enumerateSubstrings(in: trimmed.startIndex..., options: .bySentences) { substring, _, _, _ in
            guard let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sentence.isEmpty
            else {
                return
            }
            sentences.append(contentsOf: hardSplit(sentence, limit: hardSplitLimit))
        }
        guard !sentences.isEmpty else { return [] }

        var chunks: [String] = []
        var current = ""
        var activeTarget = firstTarget
        for sentence in sentences {
            if current.isEmpty {
                current = sentence
            } else if current.count + 1 + sentence.count <= activeTarget {
                current += " " + sentence
            } else {
                chunks.append(current)
                activeTarget = target
                current = sentence
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func hardSplit(_ sentence: String, limit: Int) -> [String] {
        guard sentence.count > limit else { return [sentence] }
        var pieces: [String] = []
        var remainder = Substring(sentence)
        while remainder.count > limit {
            let window = remainder.prefix(limit)
            let cut = window.lastIndex(where: \.isWhitespace) ?? window.endIndex
            let piece = remainder[..<cut].trimmingCharacters(in: .whitespaces)
            if piece.isEmpty { break }
            pieces.append(piece)
            remainder = remainder[cut...].drop(while: \.isWhitespace)
        }
        let tail = remainder.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces
    }
}

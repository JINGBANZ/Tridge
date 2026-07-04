import UIKit
import Vision

/// On-device OCR for printed date labels ("BEST BY 07/12/26"); the regex/date
/// logic lives in Core/DateLabelParser so it's testable on Linux.
enum DateLabelScanner {
    /// Recognized text lines joined with newlines, reading top to bottom.
    static func recognizeText(in image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else { return "" }
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false // dates aren't words; correction mangles them
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try VNImageRequestHandler(cgImage: cgImage).perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Full pipeline: photo → OCR → first plausible future date.
    static func scanDate(in image: UIImage) async -> Date? {
        guard let text = try? await recognizeText(in: image) else { return nil }
        return DateLabelParser.firstPlausibleDate(in: text)
    }
}

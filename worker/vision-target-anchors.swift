import Foundation
import Vision

// Local-only OCR helper. Image bytes arrive on stdin and are never persisted.
struct Input: Decodable { let image: String; let target: String }
let input = try JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
guard let data = Data(base64Encoded: input.image) else { throw NSError(domain: "TargetOCR", code: 1) }
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
request.recognitionLanguages = ["en-US", "zh-Hans"]
try VNImageRequestHandler(data: data).perform([request])
let targetPattern = input.target.filter { !$0.isWhitespace }
    .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s*")
let pattern = "(?<![A-Za-z0-9_])(?:\(targetPattern))(?![A-Za-z0-9_])"
var boxes: [[String: Double]] = []
for observation in request.results ?? [] {
    guard let candidate = observation.topCandidates(1).first,
          let range = candidate.string.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
          let location = try candidate.boundingBox(for: range) else { continue }
    let rectangle = location.boundingBox
    boxes.append(["left": rectangle.minX, "top": 1 - rectangle.maxY,
                  "right": rectangle.maxX, "bottom": 1 - rectangle.minY])
}
let result = try JSONSerialization.data(withJSONObject: boxes)
FileHandle.standardOutput.write(result)

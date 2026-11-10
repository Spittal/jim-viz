import Vision
import CoreImage
import AppKit
// Person mask PNG plus face landmarks (image pixels, y down) as JSON on stdout.
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let ci = CIImage(contentsOf: url)!
let size = ci.extent.size
let h = VNImageRequestHandler(ciImage: ci)
let seg = VNGeneratePersonSegmentationRequest()
seg.qualityLevel = .accurate
seg.outputPixelFormat = kCVPixelFormatType_OneComponent8
let lm = VNDetectFaceLandmarksRequest()
try h.perform([seg, lm])
let m = CIImage(cvPixelBuffer: seg.results!.first!.pixelBuffer)
let scaled = m.transformed(by: CGAffineTransform(scaleX: size.width / m.extent.width, y: size.height / m.extent.height))
try NSBitmapImageRep(ciImage: scaled).representation(using: .png, properties: [:])!
  .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
let f = lm.results!.max { $0.boundingBox.width < $1.boundingBox.width }!
let l = f.landmarks!
func pts(_ r: VNFaceLandmarkRegion2D?) -> [[Double]] {
  (r?.pointsInImage(imageSize: size) ?? []).map { [Double($0.x), Double(size.height - $0.y)] }
}
let out: [String: Any] = [
  "roll": f.roll?.doubleValue ?? 0, "yaw": f.yaw?.doubleValue ?? 0,
  "contour": pts(l.faceContour), "leftEye": pts(l.leftEye), "rightEye": pts(l.rightEye),
  "leftBrow": pts(l.leftEyebrow), "rightBrow": pts(l.rightEyebrow), "nose": pts(l.nose),
  "noseCrest": pts(l.noseCrest), "outerLips": pts(l.outerLips), "innerLips": pts(l.innerLips),
  "leftPupil": pts(l.leftPupil), "rightPupil": pts(l.rightPupil),
]
print(String(data: try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), encoding: .utf8)!)

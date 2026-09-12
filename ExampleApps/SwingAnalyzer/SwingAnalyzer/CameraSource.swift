// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

//  Minimal AVCaptureSession wrapper: 720p BGRA frames rotated to the interface orientation, delivered raw so the
//  session can both analyze and record them with their capture timestamps.

import AVFoundation

final class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
  enum CameraError: Error {
    case noCamera
  }

  let position: AVCaptureDevice.Position
  let previewLayer: AVCaptureVideoPreviewLayer
  /// Called on the capture queue for every frame.
  var onFrame: ((CMSampleBuffer) -> Void)?

  private let session = AVCaptureSession()
  private let output = AVCaptureVideoDataOutput()
  private let queue = DispatchQueue(label: "swing.camera")

  init(position: AVCaptureDevice.Position, orientation: AVCaptureVideoOrientation) throws {
    self.position = position
    previewLayer = AVCaptureVideoPreviewLayer(session: session)
    super.init()

    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    else { throw CameraError.noCamera }
    let input = try AVCaptureDeviceInput(device: device)

    session.beginConfiguration()
    session.sessionPreset = .hd1280x720
    session.addInput(input)
    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(self, queue: queue)
    session.addOutput(output)
    session.commitConfiguration()

    let mirrored = position == .front
    for connection in [output.connection(with: .video), previewLayer.connection] {
      guard let connection else { continue }
      connection.videoOrientation = orientation
      if connection.isVideoMirroringSupported {
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
      }
    }
    previewLayer.videoGravity = .resizeAspect
  }

  func start() {
    queue.async { [session] in
      if !session.isRunning { session.startRunning() }
    }
  }

  func stop() {
    queue.async { [session] in
      if session.isRunning { session.stopRunning() }
    }
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    onFrame?(sampleBuffer)
  }
}

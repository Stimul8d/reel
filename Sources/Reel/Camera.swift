import Foundation
@preconcurrency import AVFoundation
import CoreVideo

/// The webcam. Frames are not written anywhere on their own; the compositor
/// pulls the most recent one whenever a screen frame turns up, which is why
/// this only ever keeps one. The camera runs slower than the screen and nobody
/// can see the difference in a 200px circle.
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "reel.camera")
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private(set) var deviceName = ""
    private(set) var frames = 0

    /// Everything that can act as a webcam here: the built-in one, a USB
    /// camera, and an iPhone over Continuity.
    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified).devices
    }

    static func authorise() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// `named` matches on a substring of the device name, so "iPhone" or
    /// "FaceTime" both work. Nil takes the first one going.
    func start(named: String? = nil) throws {
        let all = Camera.devices()
        guard !all.isEmpty else { throw Err("no camera found") }
        let device = named.flatMap { n in
            all.first { $0.localizedName.localizedCaseInsensitiveContains(n) }
        } ?? all[0]
        deviceName = device.localizedName

        session.beginConfiguration()
        // 720p is more than a circle a couple of hundred pixels across can show,
        // and it keeps the camera off the high-power capture formats.
        session.sessionPreset = .hd1280x720
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw Err("cannot open \(device.localizedName)") }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        // A late camera frame is worthless: the compositor only ever wants the
        // newest one, so throw the backlog away rather than queue it.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw Err("cannot add camera output") }
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
    }

    func stop() {
        session.stopRunning()
        lock.lock(); latest = nil; lock.unlock()
    }

    var isRunning: Bool { session.isRunning }

    func currentFrame() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        latest = px
        frames += 1
        lock.unlock()
    }
}

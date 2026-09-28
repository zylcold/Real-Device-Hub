import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AppKit

/// Capture settings applied to every tile. Not user-tunable — the dashboard is
/// a glance, not a player.
enum CaptureProfile {
    static let fps = 30
    /// Per device. Three devices on a Pro/M-series holds ~12 Mbps total.
    static let bitrate = 4_000_000
}

/// One `SCStream` on one Simulator window, plus its H.264 encoder.
///
/// A device with several screens has one of these per screen, created lazily
/// when a viewer asks for that screen.
final class DeviceCapture: NSObject, @unchecked Sendable {
    let device: SimDevice
    /// Which of the device's screens this capture streams.
    let screen: Int

    var onSendJSON: (([String: Any]) -> Void)?
    var onSendBinaryFrame: ((_ isKey: Bool, _ ptsMicros: Int64, _ annexB: Data) -> Void)?

    private let encoder = H264Encoder(bitrate: CaptureProfile.bitrate, fps: CaptureProfile.fps)
    private var stream: SCStream?
    private var filter: SCContentFilter?
    private var streamConfig: SCStreamConfiguration?
    private let streamQueue = DispatchQueue(label: "com.simfleet.capture")
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastEncodedBufferPtr: UnsafeMutableRawPointer?
    private var forceNextEncode = true
    private var viewerAttached = false
    /// Codec announced by the encoder once SPS is parsed. Cached so a viewer
    /// that joins after the first frame still learns how to configure its
    /// decoder. The dashboard also needs it to size tiles to the real aspect
    /// ratio before any video arrives.
    private var lastCodec: String?
    private var lastWidth = 0
    private var lastHeight = 0
    private let sizeLock = NSLock()

    /// Encoded size, or .zero until the encoder has configured.
    var outputSize: CGSize {
        sizeLock.lock()
        defer { sizeLock.unlock() }
        return CGSize(width: lastWidth, height: lastHeight)
    }

    init(device: SimDevice, screen: Int) {
        self.device = device
        self.screen = screen
        super.init()

        encoder.onConfig = { [weak self] codec, width, height in
            guard let self else { return }
            self.sizeLock.lock()
            self.lastCodec = codec
            self.lastWidth = width
            self.lastHeight = height
            self.sizeLock.unlock()
            print("[Capture \(self.label)] codec=\(codec) \(width)x\(height)")
            self.sendVideoInit()
        }
        encoder.onFrame = { [weak self] isKey, data, pts in
            guard let self, self.viewerAttached else { return }
            self.onSendBinaryFrame?(isKey, pts, data)
        }
    }

    /// Human label for logs — screen 0 has no suffix.
    var label: String {
        device.windowCount > 1 ? "\(device.name) [screen \(screen)]" : device.name
    }

    // MARK: - Lifecycle

    func start() async throws {
        guard let window = device.windows[safe: screen], let object = window.object else {
            throw CaptureError.noWindow
        }

        let contentFilter = SCContentFilter(desktopIndependentWindow: object)
        let config = makeConfiguration(for: window)
        self.filter = contentFilter
        self.streamConfig = config

        let captureStream = SCStream(filter: contentFilter, configuration: config, delegate: nil)
        try captureStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: streamQueue)
        try await captureStream.startCapture()
        self.stream = captureStream
        print("[Capture \(label)] started")
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        // The encoder is only safe to tear down from the thread that encodes.
        streamQueue.sync { self.encoder.invalidate() }
    }

    // MARK: - Viewer

    /// Called when a viewer attaches. Safe to call for every viewer: it
    /// re-announces the codec config and forces a keyframe, which is exactly
    /// what a viewer arriving after the capture is already running needs.
    func viewerJoined() {
        viewerAttached = true
        forceNextEncode = true
        sendVideoInit()
        encoder.requestKeyframe()
        // SCStream only delivers on content change, so a static screen would
        // leave the viewer on a black tile. Push what we have (or a fresh
        // screenshot) right away.
        streamQueue.async { self.pushOneFrame() }
    }

    func viewerLeft() {
        viewerAttached = false
    }

    func requestKeyframe() {
        forceNextEncode = true
        encoder.requestKeyframe()
        // A still screen makes SCStream silent, so the flag alone can sit
        // unfulfilled for seconds and a viewer that lost its decoder stays
        // black. Re-encode what we already have so the request is served now.
        streamQueue.async { self.pushOneFrame() }
    }

    // MARK: - Configuration

    private func makeConfiguration(for window: SimWindow) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(CaptureProfile.fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false

        // Crop the window's chrome off so the tile keeps the screen's real
        // proportions. If no display geometry matches we capture the whole
        // window rather than guess.
        var content = window.size
        if let contentRect = device.contentRect(forWindow: window) {
            config.sourceRect = contentRect
            content = contentRect.size
            print("[Capture \(label)] screen \(Int(contentRect.width))x\(Int(contentRect.height)) " +
                  "of window \(Int(window.size.width))x\(Int(window.size.height))")
        }

        // State the output size explicitly, and make it the *source* size. Both
        // halves matter:
        //   • with sourceRect but no width/height, ScreenCaptureKit falls back to
        //     the display size and we get a 1920x1080 frame with the device
        //     sitting in its top-left corner;
        //   • asking for a *scaled* size makes it deliver buffers at both sizes,
        //     the encoder rebuilds its session on every flip, and the viewer
        //     draws a 440x956 frame into a 588x1280 canvas — black bars down the
        //     right and bottom.
        // H.264 4:2:0 also needs even dimensions; window widths are arbitrary
        // (437, 643, 671 on a Retina Mac) and an odd one comes back as
        // kVTPixelTransferNotSupportedErr (-12905) with no frame at all.
        config.width = even(Int(content.width))
        config.height = even(Int(content.height))
        // ponytail: a 13" iPad would stream at its full ~2064x2752. Downscale in
        // the browser instead — the canvas is ~240px wide and is already
        // throwing most of the pixels away.
        return config
    }

    private func even(_ value: Int) -> Int {
        max(2, value & ~1)
    }

    private func pushOneFrame() {
        if let buf = lastPixelBuffer {
            let ts = CMTime(value: Int64(CACurrentMediaTime() * 1000), timescale: 1000)
            encode(buf, ts)
            return
        }
        guard let filter, let config = streamConfig else { return }
        Task {
            guard let image = try? await SCScreenshotManager.captureSampleBuffer(
                contentFilter: filter, configuration: config
            ), let pixelBuffer = image.imageBuffer else { return }
            self.lastPixelBuffer = pixelBuffer
            self.encode(pixelBuffer, CMTime(value: Int64(CACurrentMediaTime() * 1000), timescale: 1000))
        }
    }

    private func encode(_ pixelBuffer: CVPixelBuffer, _ ts: CMTime) {
        let ptr = Unmanaged.passUnretained(pixelBuffer).toOpaque()
        if ptr == lastEncodedBufferPtr && !forceNextEncode { return }
        lastEncodedBufferPtr = ptr
        forceNextEncode = false
        encoder.encode(pixelBuffer, pts: ts)
    }

    private func sendVideoInit() {
        sizeLock.lock()
        let codec = lastCodec, width = lastWidth, height = lastHeight
        sizeLock.unlock()
        guard let codec, width > 0, height > 0 else { return }
        onSendJSON?([
            "type": "video-init",
            "key": device.key,
            "codec": codec,
            "width": lastWidth,
            "height": lastHeight
        ])
    }
}

extension DeviceCapture: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        lastPixelBuffer = pixelBuffer
        encode(pixelBuffer, sampleBuffer.presentationTimeStamp)
    }
}

enum CaptureError: Error {
    case noWindow
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

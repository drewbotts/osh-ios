import SwiftUI
import AVFoundation

// MARK: - CameraPreviewView
//
// Shows what the camera is capturing by attaching an
// AVCaptureVideoPreviewLayer to the session VideoOutput is already running.
// The preview is a second consumer of the same capture session, not a second
// session — starting another one would fight the encoder for the device.
//
// .resizeAspect letterboxes rather than crops: the point of this view is to
// confirm the framing that is actually being encoded, so showing less of the
// frame than the node receives would defeat it.

struct CameraPreviewView: UIViewRepresentable {

    let captureSession: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = captureSession
        view.previewLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        if view.previewLayer.session !== captureSession {
            view.previewLayer.session = captureSession
        }
    }

    /// Backing the view with the preview layer directly — rather than adding it
    /// as a sublayer — is what keeps it sized correctly through rotation and
    /// layout changes without any manual frame bookkeeping.
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // Safe by construction: layerClass above guarantees the type.
            guard let layer = layer as? AVCaptureVideoPreviewLayer else {
                fatalError("layerClass must be AVCaptureVideoPreviewLayer")
            }
            return layer
        }
    }
}

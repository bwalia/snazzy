import SnazzyCore

/// Capture engine: devices, sessions, compositing, writer, sync, calibration.
///
/// Phase 2 provides device discovery (`DeviceCatalog`), live camera feeds
/// with stall detection (`CameraFeed`, `FeedManager`), the inset transform
/// (`FrameTransform`) and a preview view (`FramePreviewView`).
///
/// Consumers never add outputs to a running `AVCaptureSession`: every feed has
/// one video data output configured before it starts, and previews (and the
/// recorder in phase 3) read frames from the feed's `FrameReceiver`.
public enum CaptureEngine {}

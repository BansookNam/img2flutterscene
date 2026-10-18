import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // Three panels (models, viewer, inspector) need room: open large, centred.
    let size = NSSize(width: 1440, height: 900)
    let screen = NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: size)
    let frame = NSRect(
      x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
      width: min(size.width, screen.width), height: min(size.height, screen.height))
    self.setFrame(frame, display: true)
    self.minSize = NSSize(width: 1100, height: 700)
    self.title = "img2flutterscene"

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}

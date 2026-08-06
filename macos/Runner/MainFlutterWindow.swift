import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var lastChangeCount: Int = -1

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "ai.augustyniak.capture/clipboard",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else { return }
      if call.method == "getClipboardImage" {
        result(self.getClipboardImage())
      } else if call.method == "getClipboardHistoryDirectory" {
        result(self.clipboardHistoryDirectory()?.path)
      } else if call.method == "copyImageToClipboard" {
        if let args = call.arguments as? [String: Any], let path = args["path"] as? String {
          self.copyImageToClipboard(path: path)
          result(true)
        } else {
          result(false)
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }

  private func clipboardHistoryDirectory() -> URL? {
    guard let baseURL = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else { return nil }
    let directory = baseURL.appendingPathComponent("AugustyniakCapture", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      return directory
    } catch {
      return nil
    }
  }

  private func getClipboardImage() -> String? {
    let pasteboard = NSPasteboard.general
    if pasteboard.changeCount == lastChangeCount {
      return nil
    }

    let types = pasteboard.types ?? []
    let hasImage = types.contains(.tiff) || types.contains(.png)
    if !hasImage {
      return nil
    }

    guard let data = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png),
          let image = NSImage(data: data),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return nil
    }

    lastChangeCount = pasteboard.changeCount

    let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
    guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
      return nil
    }

    let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let imagesDir = documentsDir.appendingPathComponent("AugustyniakCapture/images")
    try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

    let filename = "clip_\(UUID().uuidString).png"
    let fileURL = imagesDir.appendingPathComponent(filename)

    do {
      try pngData.write(to: fileURL)
      return fileURL.path
    } catch {
      return nil
    }
  }

  private func copyImageToClipboard(path: String) {
    guard let image = NSImage(contentsOfFile: path) else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects([image])
    lastChangeCount = pasteboard.changeCount
  }
}

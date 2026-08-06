import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    NativeMediaProcessor.register(with: engineBridge.applicationRegistrar.messenger())
    let channel = FlutterMethodChannel(
      name: "ai.augustyniak.capture/clipboard",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "getClipboardHistoryDirectory" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let baseURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.ai.augustyniak.capture"
      ) ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      let directory = baseURL.appendingPathComponent("AugustyniakCapture", isDirectory: true)
      do {
        try FileManager.default.createDirectory(
          at: directory,
          withIntermediateDirectories: true
        )
        result(directory.path)
      } catch {
        result(FlutterError(
          code: "clipboard_storage_error",
          message: error.localizedDescription,
          details: nil
        ))
      }
    }
  }
}

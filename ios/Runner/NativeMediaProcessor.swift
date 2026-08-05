import AVFoundation
import Flutter
import UIKit

/// Sandboxed media processing implemented with Apple's system frameworks.
/// Source files are read-only; every output is a derived artifact owned by Dart.
final class NativeMediaProcessor {
  private static let channelName = "ai.augustyniak.capture/media_processing"

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard let arguments = call.arguments as? [String: Any] else {
        result(error("invalid_arguments", "Expected a map of arguments."))
        return
      }

      switch call.method {
      case "extractVideoAudio":
        guard
          let sourcePath = arguments["sourcePath"] as? String,
          let outputPath = arguments["outputPath"] as? String
        else {
          result(error("invalid_arguments", "Missing sourcePath or outputPath."))
          return
        }
        exportAudio(sourcePath: sourcePath, outputPath: outputPath, timeRange: nil) {
          resultFrom($0, flutterResult: result)
        }

      case "extractVideoPoster":
        guard
          let sourcePath = arguments["sourcePath"] as? String,
          let outputPath = arguments["outputPath"] as? String
        else {
          result(error("invalid_arguments", "Missing sourcePath or outputPath."))
          return
        }
        extractPoster(sourcePath: sourcePath, outputPath: outputPath) {
          resultFrom($0, flutterResult: result)
        }

      case "splitAudio":
        guard
          let sourcePath = arguments["sourcePath"] as? String,
          let outputDirectory = arguments["outputDirectory"] as? String,
          let segmentMilliseconds = arguments["segmentMilliseconds"] as? NSNumber,
          segmentMilliseconds.int64Value > 0
        else {
          result(error("invalid_arguments", "Missing paths or positive segment duration."))
          return
        }
        splitAudio(
          sourcePath: sourcePath,
          outputDirectory: outputDirectory,
          segmentDuration: Double(segmentMilliseconds.int64Value) / 1_000
        ) { splitResult in
          switch splitResult {
          case .success(let paths): result(paths)
          case .failure(let failure): result(flutterError(from: failure))
          }
        }

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func exportAudio(
    sourcePath: String,
    outputPath: String,
    timeRange: CMTimeRange?,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: sourcePath))
    guard !asset.tracks(withMediaType: .audio).isEmpty else {
      completion(.failure(MediaFailure("Media contains no audio track.")))
      return
    }
    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)
    else {
      completion(.failure(MediaFailure("Apple M4A export is unavailable for this media.")))
      return
    }

    let outputURL = URL(fileURLWithPath: outputPath)
    do {
      try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if FileManager.default.fileExists(atPath: outputPath) {
        try FileManager.default.removeItem(at: outputURL)
      }
    } catch {
      completion(.failure(error))
      return
    }

    session.outputURL = outputURL
    session.outputFileType = .m4a
    if let timeRange { session.timeRange = timeRange }
    session.exportAsynchronously {
      DispatchQueue.main.async {
        switch session.status {
        case .completed:
          let attributes = try? FileManager.default.attributesOfItem(atPath: outputPath)
          let outputSize = attributes?[.size] as? NSNumber
          guard
            FileManager.default.fileExists(atPath: outputPath),
            outputSize?.int64Value ?? 0 > 0
          else {
            completion(.failure(MediaFailure("Audio export produced no output.")))
            return
          }
          completion(.success(()))
        case .failed, .cancelled:
          completion(.failure(session.error ?? MediaFailure("Audio export failed.")))
        default:
          completion(.failure(MediaFailure("Audio export ended in state \(session.status.rawValue).")))
        }
      }
    }
  }

  private static func splitAudio(
    sourcePath: String,
    outputDirectory: String,
    segmentDuration: Double,
    completion: @escaping (Result<[String], Error>) -> Void
  ) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: sourcePath))
    let duration = asset.duration.seconds
    guard duration.isFinite, duration > 0 else {
      completion(.failure(MediaFailure("Audio duration is unavailable.")))
      return
    }
    do {
      try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: outputDirectory),
        withIntermediateDirectories: true
      )
    } catch {
      completion(.failure(error))
      return
    }

    let count = max(1, Int(ceil(duration / segmentDuration)))
    var paths: [String] = []

    func exportSegment(_ index: Int) {
      guard index < count else {
        completion(.success(paths))
        return
      }
      let start = Double(index) * segmentDuration
      let remaining = max(0, duration - start)
      let length = min(segmentDuration, remaining)
      let outputPath = URL(fileURLWithPath: outputDirectory)
        .appendingPathComponent(String(format: "part_%05d.m4a", index))
        .path
      let range = CMTimeRange(
        start: CMTime(seconds: start, preferredTimescale: 600),
        duration: CMTime(seconds: length, preferredTimescale: 600)
      )
      exportAudio(sourcePath: sourcePath, outputPath: outputPath, timeRange: range) { exportResult in
        switch exportResult {
        case .success:
          paths.append(outputPath)
          exportSegment(index + 1)
        case .failure(let failure):
          completion(.failure(failure))
        }
      }
    }

    exportSegment(0)
  }

  private static func extractPoster(
    sourcePath: String,
    outputPath: String,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let asset = AVURLAsset(url: URL(fileURLWithPath: sourcePath))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        let seconds = asset.duration.seconds
        let requestedSecond = seconds.isFinite && seconds > 0 ? min(1, max(0, seconds - 0.001)) : 0
        let image = try generator.copyCGImage(
          at: CMTime(seconds: requestedSecond, preferredTimescale: 600),
          actualTime: nil
        )
        guard let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) else {
          throw MediaFailure("Could not encode the video poster.")
        }
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
          at: outputURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: .atomic)
        DispatchQueue.main.async { completion(.success(())) }
      } catch {
        DispatchQueue.main.async { completion(.failure(error)) }
      }
    }
  }

  private static func resultFrom(
    _ operation: Result<Void, Error>,
    flutterResult: FlutterResult
  ) {
    switch operation {
    case .success: flutterResult(nil)
    case .failure(let failure): flutterResult(flutterError(from: failure))
    }
  }

  private static func flutterError(from error: Error) -> FlutterError {
    self.error("native_media_error", error.localizedDescription)
  }

  private static func error(_ code: String, _ message: String) -> FlutterError {
    FlutterError(code: code, message: message, details: nil)
  }
}

private struct MediaFailure: LocalizedError {
  init(_ message: String) { self.message = message }

  let message: String
  var errorDescription: String? { message }
}

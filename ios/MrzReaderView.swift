import Foundation
import UIKit
import AVFoundation
import Vision

@objc(MrzReaderView)
class MrzReaderView: MrzReaderViewBase {
	var request: VNRecognizeTextRequest!

  override func fakeViewDidLoad() {
		// Set up vision request before letting ViewController set up the camera
		// so that it exists when the first buffer is received.
		request = VNRecognizeTextRequest(completionHandler: recognizeTextHandler)

		super.fakeViewDidLoad()
  }

  // MARK: - Text recognition
	
	// Vision recognition handler.
	func recognizeTextHandler(request: VNRequest, error: Error?) {
		var recognizedStrings = [String]()

		guard let results = request.results as? [VNRecognizedTextObservation] else {
			return
		}
		
		let maximumCandidates = 10
		for visionResult in results {
			for candidate in visionResult.topCandidates(maximumCandidates) {
				recognizedStrings.append(candidate.string)
			}
		}
		
		// Hide debug bounding boxes in production scanning UI.
		DispatchQueue.main.async {
			self.removeBoxes()
		}
		
		// Build and validate TD3 MRZ from this frame only.
		guard let mrzString = parseTd3Mrz(from: recognizedStrings) else {
			return
		}
		showString(string: mrzString)
	}
	
	override func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
		if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
			// Configure for running in real-time.
			request.recognitionLevel = .fast
			request.recognitionLanguages = ["en-US"]
			// Language correction won't help recognizing phone numbers. It also
			// makes recognition slower.
			request.usesLanguageCorrection = false
			// Only run on the region of interest for maximum speed.
			request.regionOfInterest = regionOfInterest
			
			let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: textOrientation, options: [:])
			do {
				try requestHandler.perform([request])
			} catch {
				print(error)
			}
		}
	}
}


class MrzReaderViewBase: UIView, AVCaptureVideoDataOutputSampleBufferDelegate {
	// MARK: - UI objects
  var previewLayer: AVCaptureVideoPreviewLayer!
	var maskLayer = CAShapeLayer()
	private var onMRZRead: RCTBubblingEventBlock?
    // Device orientation. Updated whenever the orientation changes to a
	// different supported orientation.
	var currentOrientation = UIDeviceOrientation.portrait

  // MARK: - Capture related objects
  let captureSession = AVCaptureSession()
    let captureSessionQueue = DispatchQueue(label: "com.example.apple-samplecode.CaptureSessionQueue")

  var captureDevice: AVCaptureDevice?

  var videoDataOutput = AVCaptureVideoDataOutput()
    let videoDataOutputQueue = DispatchQueue(label: "com.example.apple-samplecode.VideoDataOutputQueue")

  // MARK: - Region of interest (ROI) and text orientation
	// Region of video data output buffer that recognition should be run on.
	// Gets recalculated once the bounds of the preview layer are known.
	var regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
	// Orientation of text to search for in the region of interest.
	var textOrientation = CGImagePropertyOrientation.up

  // MARK: - Coordinate transforms
	var bufferAspectRatio: Double!
	// Transform from UI orientation to buffer orientation.
	var uiRotationTransform = CGAffineTransform.identity
	// Transform bottom-left coordinates to top-left.
	var bottomToTopTransform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -1)
	// Transform coordinates in ROI to global coordinates (still normalized).
	var roiToGlobalTransform = CGAffineTransform.identity
	
	// Vision -> AVF coordinate transform.
	var visionToAVFTransform = CGAffineTransform.identity
	// Debug bounding boxes are intentionally disabled in this app.
	var boxLayer = [CAShapeLayer]()

  // MARK: - View controller methods


  override init(frame: CGRect) {
      super.init(frame: frame)
      fakeViewDidLoad()
  }

  required init?(coder: NSCoder) {
      super.init(coder: coder)
      fakeViewDidLoad()
  }

  func fakeViewDidLoad() {

    // Set up preview view.
    // previewView.session = captureSession
    previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
		maskLayer.backgroundColor = UIColor.clear.cgColor
		maskLayer.fillRule = .evenOdd

    previewLayer.videoGravity = .resizeAspectFill
    previewLayer.frame = self.bounds
    self.layer.addSublayer(previewLayer)

    // Starting the capture session is a blocking call. Perform setup using
    // a dedicated serial dispatch queue to prevent blocking the main thread.
    captureSessionQueue.async {
      self.setupCamera()
      
      // Calculate region of interest now that the camera is setup.
      DispatchQueue.main.async {
        // Figure out initial ROI.
        self.calculateRegionOfInterest()
      }
    }
  }

  // lets not support orientation change for now :(
  // override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
	// 	super.viewWillTransition(to: size, with: coordinator)

	// 	// Only change the current orientation if the new one is landscape or
	// 	// portrait. You can't really do anything about flat or unknown.
	// 	let deviceOrientation = UIDevice.current.orientation
	// 	if deviceOrientation.isPortrait || deviceOrientation.isLandscape {
	// 		currentOrientation = deviceOrientation
	// 	}
		
	// 	// Handle device orientation in the preview layer.
	// 	if let videoPreviewLayerConnection = previewView.videoPreviewLayer.connection {
	// 		if let newVideoOrientation = AVCaptureVideoOrientation(deviceOrientation: deviceOrientation) {
	// 			videoPreviewLayerConnection.videoOrientation = newVideoOrientation
	// 		}
	// 	}
		
	// 	// Orientation changed: figure out new region of interest (ROI).
	// 	calculateRegionOfInterest()
	// }

  	// MARK: - Setup
	
	func calculateRegionOfInterest() {
		// Fixed ROI: full width and quarter height (normalized coordinates).
		let size = CGSize(width: 1.0, height: 0.25)
		// Make it centered.
		regionOfInterest.origin = CGPoint(x: (1 - size.width) / 2, y: (1 - size.height) / 2)
		regionOfInterest.size = size
		
		// ROI changed, update transform.
		setupOrientationAndTransform()
	}

  func setupOrientationAndTransform() {
		// Recalculate the affine transform between Vision coordinates and AVF coordinates.
		
		// Compensate for region of interest.
		let roi = regionOfInterest
		roiToGlobalTransform = CGAffineTransform(translationX: roi.origin.x, y: roi.origin.y).scaledBy(x: roi.width, y: roi.height)
		
		// Compensate for orientation (buffers always come in the same orientation).
		switch currentOrientation {
		case .landscapeLeft:
			textOrientation = CGImagePropertyOrientation.up
			uiRotationTransform = CGAffineTransform.identity
		case .landscapeRight:
			textOrientation = CGImagePropertyOrientation.down
			uiRotationTransform = CGAffineTransform(translationX: 1, y: 1).rotated(by: CGFloat.pi)
		case .portraitUpsideDown:
			textOrientation = CGImagePropertyOrientation.left
			uiRotationTransform = CGAffineTransform(translationX: 1, y: 0).rotated(by: CGFloat.pi / 2)
		default: // We default everything else to .portraitUp
			textOrientation = CGImagePropertyOrientation.right
			uiRotationTransform = CGAffineTransform(translationX: 0, y: 1).rotated(by: -CGFloat.pi / 2)
		}
		
		// Full Vision ROI to AVF transform.
		visionToAVFTransform = roiToGlobalTransform.concatenating(bottomToTopTransform).concatenating(uiRotationTransform)
	}

  // private func checkCameraPermission() {
  //     switch AVCaptureDevice.authorizationStatus(for: .video) {
  //     case .authorized:
  //         // Already authorized
  //         setupCamera()
  //     case .notDetermined:
  //         // Request permission
  //         AVCaptureDevice.requestAccess(for: .video) { granted in
  //             if granted {
  //                 DispatchQueue.main.async {
  //                     self.setupCamera()
  //                 }
  //             } else {
  //                 print("Camera access denied")
  //             }
  //         }
  //     case .denied, .restricted:
  //         print("Camera access restricted or denied")
  //     @unknown default:
  //         print("Unknown camera access status")
  //     }
  // }

  private func setupCamera() {
    guard let captureDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: AVMediaType.video, position: .back) else {
      print("Could not create capture device.")
      return
    }
    self.captureDevice = captureDevice

    // NOTE:
    // Requesting 4k buffers allows recognition of smaller text but will
    // consume more power. Use the smallest buffer size necessary to keep
    // down battery usage.
    if captureDevice.supportsSessionPreset(.hd4K3840x2160) {
      captureSession.sessionPreset = AVCaptureSession.Preset.hd4K3840x2160
      bufferAspectRatio = 3840.0 / 2160.0
    } else {
      captureSession.sessionPreset = AVCaptureSession.Preset.hd1920x1080
      bufferAspectRatio = 1920.0 / 1080.0
    }

    guard let deviceInput = try? AVCaptureDeviceInput(device: captureDevice) else {
      print("Could not create device input.")
      return
    }
    if captureSession.canAddInput(deviceInput) {
      captureSession.addInput(deviceInput)
    }

    // Configure video data output.
    videoDataOutput.alwaysDiscardsLateVideoFrames = true
    videoDataOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
    videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
    if captureSession.canAddOutput(videoDataOutput) {
      captureSession.addOutput(videoDataOutput)
      // NOTE:
      // Enable stabilization for sharper OCR frames, especially in low light.
      // Debug bounding boxes are disabled, so the previous overlay trade-off
      // no longer applies.
      videoDataOutput.connection(with: AVMediaType.video)?.preferredVideoStabilizationMode = .auto
    } else {
      print("Could not add VDO output")
      return
    }

    // Set zoom and autofocus to help focus on very small text.
    do {
      try captureDevice.lockForConfiguration()
            captureDevice.videoZoomFactor = 1.0
      captureDevice.autoFocusRangeRestriction = .near
      captureDevice.unlockForConfiguration()
    } catch {
      print("Could not set zoom level due to error: \(error)")
      return
    }

    captureSession.startRunning()
  }

  // MARK: - UI drawing and interaction
	
	// Remove all drawn boxes. Must be called on main queue.
	func removeBoxes() {
		for layer in boxLayer {
			layer.removeFromSuperlayer()
		}
		boxLayer.removeAll()
	}
	
	func showString(string: String) {
    DispatchQueue.main.async {
      // print("mrz: " + string)
      self.onMRZRead?(["mrz": string.replacingOccurrences(of: "\n", with: "")])
    }
		// Found a definite number.
		// Stop the camera synchronously to ensure that no further buffers are
		// received. Then update the number view asynchronously.
		/*captureSessionQueue.sync {
			self.captureSession.stopRunning()
        DispatchQueue.main.async {
          self.onMRZRead?(["mrz": string])
        }
		}*/
	}

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if self.window != nil {
      // print("start running")
      // Start scanning when the view is visible
      captureSessionQueue.async {
        if !self.captureSession.isRunning {
            self.captureSession.startRunning()
        }
      }
    } else {
      // print("stop running")
      // Stop scanning when the view is no longer visible
      captureSessionQueue.sync {
        self.captureSession.stopRunning()
      }
    }
  }

  @objc func setOnMRZRead(_ callback: @escaping RCTBubblingEventBlock) {
      self.onMRZRead = callback
  }

  override func layoutSubviews() {
      super.layoutSubviews()
      previewLayer?.frame = self.bounds
  }

	func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
		// This is implemented in MrzReaderView.
	}
}

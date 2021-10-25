import UIKit
import Combine
import AVFoundation
import SoundAnalysis

final class ViewController: UIViewController {
    private let fileOutput = AVCaptureMovieFileOutput()
    private var recordButton: UIButton!

    private var audioEngine: AVAudioEngine?
    private var analyzer: SNAudioStreamAnalyzer?

    private var subject: PassthroughSubject<SNClassificationResult, Error>?
    private var detectionCancellable: AnyCancellable? = nil

    private let analysisQueue = DispatchQueue(label: "com.tsuzuki817.sound-analysiss.sample.AnalysisQueue")
    private var retainedObservers: [SNResultsObserving]?

    @Published var soundDetectionIsRunning: Bool = false
    var isMusic: Bool = false

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .black
        self.setUpCamera()

        let classificationSubject = PassthroughSubject<SNClassificationResult, Error>()

        detectionCancellable =
        classificationSubject
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in self.soundDetectionIsRunning = false },
                  receiveValue: { [weak self] _ in
                self?.isMusic = true
            })

        startSoundClassification(subject: classificationSubject, inferenceWindowSize: Double(1.5), overlapFactor: Double(0.9))
    }


    private func startAudioSession() throws {
        stopAudioSession()
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .default)
            try audioSession.setActive(true)
        } catch {
            stopAudioSession()
            throw error
        }
    }

    private func stopAudioSession() {
        autoreleasepool {
            let audioSession = AVAudioSession.sharedInstance()
            try? audioSession.setActive(false)
        }
    }

    func startSoundClassification(subject: PassthroughSubject<SNClassificationResult, Error>, inferenceWindowSize: Double, overlapFactor: Double) {
        stopSoundClassification()

        do {
            let observer = SampleObserver(subject: subject)

            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTimeMakeWithSeconds(inferenceWindowSize, preferredTimescale: 48_000)
            request.overlapFactor = overlapFactor

            self.subject = subject

            startListeningForAudioSessionInterruptions()
            try startAnalyzing([(request, observer)])
        } catch {
            subject.send(completion: .failure(error))
            self.subject = nil
            stopSoundClassification()
        }
    }

    func stopSoundClassification() {
        stopAnalyzing()
        stopListeningForAudioSessionInterruptions()
    }

    private func startListeningForAudioSessionInterruptions() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption),
            name: AVAudioSession.mediaServicesWereLostNotification,
            object: nil)
    }

    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        let error = SystemAudioClassificationError.audioStreamInterrupted
        subject?.send(completion: .failure(error))
        stopSoundClassification()
    }

    private func stopListeningForAudioSessionInterruptions() {
        NotificationCenter.default.removeObserver(
            self,
            name: AVAudioSession.interruptionNotification,
            object: nil)
        NotificationCenter.default.removeObserver(
            self,
            name: AVAudioSession.mediaServicesWereLostNotification,
            object: nil)
    }

    private func startAnalyzing(_ requestsAndObservers: [(SNRequest, SNResultsObserving)]) throws {
        stopAnalyzing()

        do {
            try startAudioSession()

            try ensureMicrophoneAccess()

            let newAudioEngine = AVAudioEngine()
            audioEngine = newAudioEngine

            let busIndex = AVAudioNodeBus(0)
            let bufferSize = AVAudioFrameCount(4096)
            let audioFormat = newAudioEngine.inputNode.outputFormat(forBus: busIndex)

            let newAnalyzer = SNAudioStreamAnalyzer(format: audioFormat)
            analyzer = newAnalyzer

            try requestsAndObservers.forEach { try newAnalyzer.add($0.0, withObserver: $0.1) }
            retainedObservers = requestsAndObservers.map { $0.1 }

            newAudioEngine.inputNode.installTap(
                onBus: busIndex,
                bufferSize: bufferSize,
                format: audioFormat,
                block: { (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
                    self.analysisQueue.async {
                        newAnalyzer.analyze(buffer, atAudioFramePosition: when.sampleTime)
                    }
                }
            )

            try newAudioEngine.start()
        } catch {
            stopAnalyzing()
            throw error
        }
    }

    private func ensureMicrophoneAccess() throws {
        var hasMicrophoneAccess = false
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            let sem = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: { success in
                hasMicrophoneAccess = success
                sem.signal()
            })
            _ = sem.wait(timeout: DispatchTime.distantFuture)
        case .denied, .restricted:
            break
        case .authorized:
            hasMicrophoneAccess = true
        @unknown default:
            fatalError("unknown authorization status for microphone access")
        }

        if !hasMicrophoneAccess {
            throw SystemAudioClassificationError.noMicrophoneAccess
        }
    }

    private func stopAnalyzing() {
        autoreleasepool {
            if let audioEngine = audioEngine {
                audioEngine.stop()
                audioEngine.inputNode.removeTap(onBus: 0)
            }

            if let analyzer = analyzer {
                analyzer.removeAllRequests()
            }

            analyzer = nil
            retainedObservers = nil
            audioEngine = nil
        }
        stopAudioSession()
    }

    // カメラの設定
    private func setUpCamera() {
        let captureSession: AVCaptureSession = AVCaptureSession()
        let videoDevice: AVCaptureDevice? = AVCaptureDevice.default(for: AVMediaType.video)
        let audioDevice: AVCaptureDevice? = AVCaptureDevice.default(for: AVMediaType.audio)

        // video input setting
        let videoInput: AVCaptureDeviceInput = try! AVCaptureDeviceInput(device: videoDevice!)
        captureSession.addInput(videoInput)

        // audio input setting
        let audioInput = try! AVCaptureDeviceInput(device: audioDevice!)
        captureSession.addInput(audioInput)

        captureSession.addOutput(fileOutput)

        captureSession.startRunning()

        // video preview layer
        let videoLayer : AVCaptureVideoPreviewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        videoLayer.frame = self.view.bounds
        videoLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
        self.view.layer.addSublayer(videoLayer)

        // recording button
        self.recordButton = UIButton(frame: CGRect(x: 0, y: 0, width: 120, height: 50))
        self.recordButton.backgroundColor = UIColor.gray
        self.recordButton.layer.masksToBounds = true
        self.recordButton.setTitle("録画する", for: .normal)
        self.recordButton.layer.cornerRadius = 20
        self.recordButton.layer.position = CGPoint(x: self.view.bounds.width / 2, y:self.view.bounds.height - 100)
        self.recordButton.addTarget(self, action: #selector(self.onClickRecordButton(sender:)), for: .touchUpInside)
        self.view.addSubview(recordButton)
    }

    @objc func onClickRecordButton(sender: UIButton) {
        if self.fileOutput.isRecording {
            // stop recording
            fileOutput.stopRecording()

            self.recordButton.backgroundColor = .gray
            self.recordButton.setTitle("録画する", for: .normal)
        } else {
            // start recording
            let tempDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory())
            let fileURL: URL = tempDirectory.appendingPathComponent("sample.mov")
            fileOutput.startRecording(to: fileURL, recordingDelegate: self)

            self.recordButton.backgroundColor = .red
            self.recordButton.setTitle("●録画中", for: .normal)
        }
    }
}

extension ViewController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        if isMusic {
            let alert: UIAlertController = UIAlertController(title: "音楽が認識されました。動画に音楽がある場合は著作権に注意してください。", message: outputFileURL.absoluteString, preferredStyle:  .alert)
            let okAction: UIAlertAction = UIAlertAction(title: "OK", style: UIAlertAction.Style.default, handler: nil)
            alert.addAction(okAction)
            self.present(alert, animated: true, completion: nil)
        } else {
            let alert: UIAlertController = UIAlertController(title: "録画完了しました", message: outputFileURL.absoluteString, preferredStyle:  .alert)
            let okAction: UIAlertAction = UIAlertAction(title: "OK", style: UIAlertAction.Style.default, handler: nil)
            alert.addAction(okAction)
            self.present(alert, animated: true, completion: nil)
        }
    }
}

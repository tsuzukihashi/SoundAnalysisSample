import SoundAnalysis
import Combine

class SampleObserver: NSObject, SNResultsObserving {
    private let subject: PassthroughSubject<SNClassificationResult, Error>

    init(subject: PassthroughSubject<SNClassificationResult, Error>) {
        self.subject = subject
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        subject.send(completion: .failure(error))
    }

    func requestDidComplete(_ request: SNRequest) {
        subject.send(completion: .finished)
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        if let result = result as? SNClassificationResult,
           let classification = result.classification(forIdentifier: "music"),
           classification.confidence > 0.5 {
            subject.send(result)
        }
    }
}

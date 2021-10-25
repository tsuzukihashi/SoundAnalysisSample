import Foundation

struct DetectionState {
    let presenceThreshold: Double

    let absenceThreshold: Double
    let presenceMeasurementsToStartDetection: Int
    let absenceMeasurementsToEndDetection: Int
    var isDetected = false
    var transitionProgress = 0
    var currentConfidence = 0.0
    init(
        presenceThreshold: Double,
        absenceThreshold: Double,
        presenceMeasurementsToStartDetection: Int,
        absenceMeasurementsToEndDetection: Int
    ) {
        self.presenceThreshold = presenceThreshold
        self.absenceThreshold = absenceThreshold
        self.presenceMeasurementsToStartDetection = presenceMeasurementsToStartDetection
        self.absenceMeasurementsToEndDetection = absenceMeasurementsToEndDetection
    }

    init(
        advancedFrom prevState: DetectionState,
        currentConfidence: Double
    ) {
        isDetected = prevState.isDetected
        transitionProgress = prevState.transitionProgress
        presenceThreshold = prevState.presenceThreshold
        absenceThreshold = prevState.absenceThreshold
        presenceMeasurementsToStartDetection = prevState.presenceMeasurementsToStartDetection
        absenceMeasurementsToEndDetection = prevState.absenceMeasurementsToEndDetection

        if isDetected {
            if currentConfidence < absenceThreshold {
                transitionProgress += 1
            } else {
                transitionProgress = 0
            }

            if transitionProgress >= absenceMeasurementsToEndDetection {
                isDetected = !isDetected
                transitionProgress = 0
            }
        } else {
            if currentConfidence > presenceThreshold {
                transitionProgress += 1
            } else {
                transitionProgress = 0
            }

            if transitionProgress >= presenceMeasurementsToStartDetection {
                isDetected = !isDetected
                transitionProgress = 0
            }
        }

        self.currentConfidence = currentConfidence
    }
}

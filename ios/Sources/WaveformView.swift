import UIKit
import QuartzCore

class WaveformView: UIView {
    private var samples: [Float] = []
    private let maxSamples: Int = 200
    private let waveformLayer = CAShapeLayer()
    private let backgroundLayer = CAShapeLayer()
    
    var waveformColor: UIColor = .systemBlue {
        didSet {
            waveformLayer.strokeColor = waveformColor.cgColor
        }
    }
    
    var backgroundColorWave: UIColor = .systemGray5 {
        didSet {
            backgroundLayer.strokeColor = backgroundColorWave.cgColor
        }
    }
    
    var lineWidth: CGFloat = 2.0 {
        didSet {
            waveformLayer.lineWidth = lineWidth
            backgroundLayer.lineWidth = lineWidth
        }
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayers()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }
    
    private func setupLayers() {
        backgroundLayer.fillColor = UIColor.clear.cgColor
        backgroundLayer.strokeColor = backgroundColorWave.cgColor
        backgroundLayer.lineWidth = lineWidth
        backgroundLayer.lineCap = .round
        backgroundLayer.lineJoin = .round
        backgroundLayer.opacity = 0.3
        layer.addSublayer(backgroundLayer)
        
        waveformLayer.fillColor = UIColor.clear.cgColor
        waveformLayer.strokeColor = waveformColor.cgColor
        waveformLayer.lineWidth = lineWidth
        waveformLayer.lineCap = .round
        waveformLayer.lineJoin = .round
        layer.addSublayer(waveformLayer)
        
        clipsToBounds = true
    }
    
    func addSample(_ sample: Float) {
        samples.append(abs(sample))
        
        if samples.count > maxSamples {
            samples.removeFirst()
        }
        
        setNeedsDisplay()
    }
    
    func clear() {
        samples.removeAll()
        setNeedsDisplay()
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        waveformLayer.frame = bounds
        backgroundLayer.frame = bounds
        setNeedsDisplay()
    }
    
    override func draw(_ rect: CGRect) {
        super.draw(rect)
        
        let height = bounds.height
        let width = bounds.width
        let midY = height / 2.0
        
        if samples.isEmpty {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 0, y: midY))
            path.addLine(to: CGPoint(x: width, y: midY))
            waveformLayer.path = path.cgPath
            backgroundLayer.path = path.cgPath
            return
        }
        
        let xStep = width / CGFloat(maxSamples)
        
        let waveformPath = UIBezierPath()
        let backgroundPath = UIBezierPath()
        
        let emptySamples = maxSamples - samples.count
        
        for i in 0..<maxSamples {
            let x = CGFloat(i) * xStep
            var sampleValue: Float = 0
            
            if i >= emptySamples {
                let sampleIndex = i - emptySamples
                sampleValue = samples[sampleIndex]
            }
            
            let amplitude = CGFloat(min(max(sampleValue, 0), 1.0)) * (height * 0.4)
            
            let topY = midY - amplitude
            let bottomY = midY + amplitude
            
            if i == 0 {
                waveformPath.move(to: CGPoint(x: x, y: topY))
                backgroundPath.move(to: CGPoint(x: x, y: bottomY))
            } else {
                waveformPath.addLine(to: CGPoint(x: x, y: topY))
                backgroundPath.addLine(to: CGPoint(x: x, y: bottomY))
            }
        }
        
        for i in stride(from: maxSamples - 1, through: 0, by: -1) {
            let x = CGFloat(i) * xStep
            var sampleValue: Float = 0
            
            if i >= emptySamples {
                let sampleIndex = i - emptySamples
                sampleValue = samples[sampleIndex]
            }
            
            let amplitude = CGFloat(min(max(sampleValue, 0), 1.0)) * (height * 0.4)
            let bottomY = midY + amplitude
            
            waveformPath.addLine(to: CGPoint(x: x, y: bottomY))
        }
        
        waveformPath.close()
        
        waveformLayer.path = waveformPath.cgPath
        backgroundLayer.path = backgroundPath.cgPath
        
        drawCenterLine()
    }
    
    private func drawCenterLine() {
        let midY = bounds.height / 2.0
        let centerLine = UIBezierPath()
        centerLine.move(to: CGPoint(x: 0, y: midY))
        centerLine.addLine(to: CGPoint(x: bounds.width, y: midY))
        
        let centerLayer = CAShapeLayer()
        centerLayer.path = centerLine.cgPath
        centerLayer.strokeColor = UIColor.systemGray3.cgColor
        centerLayer.lineWidth = 0.5
        centerLayer.lineDashPattern = [4, 4]
        
        layer.sublayers?.filter { $0.name == "centerLine" }.forEach { $0.removeFromSuperlayer() }
        centerLayer.name = "centerLine"
        layer.insertSublayer(centerLayer, at: 0)
    }
    
    func animateSuccess() {
        let originalColor = waveformColor
        waveformColor = .systemGreen
        
        let pulseAnimation = CABasicAnimation(keyPath: "opacity")
        pulseAnimation.fromValue = 1.0
        pulseAnimation.toValue = 0.5
        pulseAnimation.duration = 0.3
        pulseAnimation.autoreverses = true
        pulseAnimation.repeatCount = 3
        waveformLayer.add(pulseAnimation, forKey: "pulse")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            self?.waveformColor = originalColor
        }
    }
    
    func animateFailure() {
        let originalColor = waveformColor
        waveformColor = .systemRed
        
        let shakeAnimation = CABasicAnimation(keyPath: "position")
        shakeAnimation.duration = 0.1
        shakeAnimation.repeatCount = 5
        shakeAnimation.autoreverses = true
        shakeAnimation.fromValue = NSValue(cgPoint: CGPoint(x: waveformLayer.position.x - 5, y: waveformLayer.position.y))
        shakeAnimation.toValue = NSValue(cgPoint: CGPoint(x: waveformLayer.position.x + 5, y: waveformLayer.position.y))
        waveformLayer.add(shakeAnimation, forKey: "shake")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.waveformColor = originalColor
        }
    }
}

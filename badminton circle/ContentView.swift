import SwiftUI
import Combine 
import AVFoundation
import Vision
import UIKit

//  MARK: - 视频播放管理类（满足 ObservableObject 协议，无编译报错）
class VideoPlayerManager: NSObject, ObservableObject {
    // @Published 依赖 Combine 框架，导入后可正常使用
    @Published private var dummy: Bool = false
    
    let player: AVPlayer
    let videoOutput: AVPlayerItemVideoOutput
    private var notificationObserver: Any?
    
    init(videoURL: URL) {
        // 配置硬编码视频输出（兼容低版本iOS，启用硬件加速）
        let videoOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920,
            kCVPixelBufferHeightKey as String: 1080
        ]
        self.videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: videoOutputSettings)
        
        // 初始化AVPlayer
        self.player = AVPlayer(url: videoURL)
        
        super.init() // 继承 NSObject 必须调用父类初始化
        
        // 延迟配置currentItem，确保网络视频初始化完成（避免nil）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else {
                print("警告：currentItem 为 nil，视频输出配置失败")
                return
            }
            
            // 给currentItem添加视频输出（硬编码帧提取必备）
            guard let currentItem = self.player.currentItem else { return }
            currentItem.add(self.videoOutput)
            
            // 配置视频循环播放通知（弱引用捕获，避免循环引用）
            self.notificationObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: currentItem,
                queue: .main
            ) { [weak self] _ in
                guard let self = self else { return }
                self.player.seek(to: .zero)
                self.player.play()
            }
        }
    }
    
    // 销毁时移除通知观察者，避免内存泄漏
    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

//  MARK: - 自定义视频播放器（硬编码帧提取，上半部分展示）
struct CustomVideoPlayerView: UIViewRepresentable {
    var player: AVPlayer
    var videoOutput: AVPlayerItemVideoOutput
    var onFrameExtracted: (CGImage) -> Void
    var videoSize: CGSize
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.frame = CGRect(origin: .zero, size: videoSize)
        
        // 配置AVPlayerLayer，展示视频
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = view.bounds
        playerLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(playerLayer)
        
        // 配置帧提取定时器（30帧/秒，平衡性能与实时性）
        context.coordinator.frameExtractionTimer = Timer.scheduledTimer(
            timeInterval: 1/30,
            target: context.coordinator,
            selector: #selector(context.coordinator.extractVideoFrame),
            userInfo: nil,
            repeats: true
        ) as Timer?
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.frame = CGRect(origin: .zero, size: videoSize)
        let playerLayer = uiView.layer.sublayers?.first as? AVPlayerLayer
        playerLayer?.player = player
        playerLayer?.frame = uiView.bounds
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    //  MARK: - 协调器（处理帧提取逻辑）
    class Coordinator: NSObject {
        var parent: CustomVideoPlayerView
        var frameExtractionTimer: Timer?
        
        init(_ parent: CustomVideoPlayerView) {
            self.parent = parent
        }
        
        // 硬编码提取视频帧（转换为CGImage供Vision检测）
        @objc func extractVideoFrame() {
            let playerItem = parent.player.currentItem
            guard let item = playerItem, parent.videoOutput.hasNewPixelBuffer(forItemTime: item.currentTime()) else {
                return
            }
            
            let itemTime = parent.videoOutput.itemTime(forHostTime: CACurrentMediaTime())
            guard let pixelBuffer = parent.videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else {
                return
            }
            
            // 转换CVPixelBuffer -> CGImage（启用硬件加速，兼容低版本）
            if let cgImage = pixelBufferToCGImage(pixelBuffer) {
                parent.onFrameExtracted(cgImage)
            }
        }
        
        // 像素缓冲区转换（移除低版本不支持的API，仅保留核心硬件加速）
        private func pixelBufferToCGImage(_ pixelBuffer: CVPixelBuffer) -> CGImage? {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let context = CIContext(options: [
                .useSoftwareRenderer: false // 禁用软件渲染，启用GPU硬件加速
            ])
            return context.createCGImage(ciImage, from: ciImage.extent)
        }
    }
}

//  MARK: - 主视图（视频上半部分展示+姿态检测叠加层）
struct ContentView: View {
    // 视频管理类（@StateObject 确保视图生命周期内唯一，无捕获歧义）
    @StateObject private var videoManager: VideoPlayerManager
    // 姿态检测叠加层（透明背景，无遮挡视频）
    @State private var poseOverlayImage: UIImage?
    // 视频展示尺寸（上半部分，屏幕高度的一半）
    @State private var videoDisplaySize: CGSize = .zero
    
    // 初始化（传入视频URL，创建视频管理类）
    init() {
        let videoURL = URL(string: "https://socratellresource.s3.eu-central-1.amazonaws.com/3209298-uhd_3840_2160_25fps.mp4")!
        self._videoManager = StateObject(wrappedValue: VideoPlayerManager(videoURL: videoURL))
    }
    
    var body: some View {
        GeometryReader { geometry in
            // 计算视频展示尺寸（屏幕宽 × 屏幕高/2，上半部分展示）
            let calculatedVideoSize = CGSize(
                width: geometry.size.width,
                height: geometry.size.height / 2
            )
            
            ZStack(alignment: .top) {
                // 背景色（白色，突出下方留白区域）
                Color.white.ignoresSafeArea()
                
                // 视频播放器 + 姿态检测叠加层（双层ZStack，无遮挡）
                ZStack(alignment: .center) {
                    // 底层：硬编码视频播放器
                    CustomVideoPlayerView(
                        player: videoManager.player,
                        videoOutput: videoManager.videoOutput,
                        onFrameExtracted: detectPoseOnVideoFrame,
                        videoSize: calculatedVideoSize
                    )
                    .frame(width: calculatedVideoSize.width, height: calculatedVideoSize.height)
                    
                    // 上层：姿态检测叠加层（透明背景，不遮挡视频）
                    if let overlayImage = poseOverlayImage {
                        Image(uiImage: overlayImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: calculatedVideoSize.width, height: calculatedVideoSize.height)
                            .allowsHitTesting(false) // 不遮挡视频交互
                    }
                }
                
                // 下方留白区域（文字说明，可扩展其他控件）
                VStack {
                    Spacer(minLength: calculatedVideoSize.height)
                    Text("姿态检测结果展示")
                        .font(.title)
                        .foregroundColor(.gray)
                    Text("视频上方为实时人体姿态检测（红色关键点+绿色骨骼）")
                        .font(.subheadline)
                        .foregroundColor(.gray.opacity(0.7)) // 浅灰色，兼容低版本SwiftUI
                        .padding(.horizontal, 20)
                        .multilineTextAlignment(.center)
                }
            }
            // 直接操作，struct 值类型无需 weak 引用
            .onAppear {
                self.videoDisplaySize = CGSize(
                    width: geometry.size.width,
                    height: geometry.size.height / 2
                )
                self.videoManager.player.play()
            }
        }
    }
    
    //  MARK: - 视频帧姿态检测（调用yolo11n-pose模型）
    private func detectPoseOnVideoFrame(_ cgImage: CGImage) {
        // 加载Core ML模型（Xcode自动生成的yolo11n_pose类）
        guard let coreMLModel = try? yolo11n_pose().model,
              let visionModel = try? VNCoreMLModel(for: coreMLModel) else {
            print("模型加载失败：请确保yolo11n-pose.mlpackage已添加到项目")
            return
        }
        
        // 配置Vision检测请求（启用硬件加速，禁用纯CPU计算）
        let request = VNCoreMLRequest(model: visionModel) { request, error in
            if let error = error {
                print("视频帧检测失败：\(error.localizedDescription)")
                return
            }
            
            // 解析检测结果，绘制姿态叠加层
            if let observations = request.results as? [VNHumanBodyPoseObservation] {
                self.drawPoseOverlay(on: cgImage, observations: observations)
            }
        }
        request.imageCropAndScaleOption = .scaleFill // 适配模型输入尺寸
        request.usesCPUOnly = false // 启用Neural Engine/GPU硬件加速
        
        // 后台执行检测，不阻塞UI线程
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            try? handler.perform([request])
        }
    }
    
    //  MARK: - 绘制姿态检测叠加层（红色关键点+绿色骨骼）
    private func drawPoseOverlay(on cgImage: CGImage, observations: [VNHumanBodyPoseObservation]) {
        // 确定叠加层尺寸（与视频展示尺寸一致，避免偏移）
        let overlaySize = videoDisplaySize == .zero ? CGSize(width: cgImage.width, height: cgImage.height) : videoDisplaySize
        
        // 开启透明绘图上下文（无背景，叠加在视频上）
        UIGraphicsBeginImageContextWithOptions(overlaySize, false, 1.0)
        guard let context = UIGraphicsGetCurrentContext() else { return }
        
        // 配置绘图样式（半透明，不遮挡视频）
        context.setStrokeColor(UIColor(red: 0, green: 1, blue: 0, alpha: 0.8).cgColor) // 绿色骨骼
        context.setLineWidth(4)
        context.setFillColor(UIColor(red: 1, green: 0, blue: 0, alpha: 0.8).cgColor) // 红色关键点
        
        // 遍历所有人体姿态观测结果，绘制关键点和骨骼
        for observation in observations {
            do {
                // 获取所有有效关键点（置信度>0.5，过滤无效结果）
                let allKeypoints = try observation.recognizedPoints(.all)
                let validKeypoints = allKeypoints.filter { $0.value.confidence > 0.5 }
                
                // 1. 绘制关键点（小圆点）
                validKeypoints.forEach { _, point in
                    let drawPoint = CGPoint(
                        x: point.location.x * overlaySize.width,
                        y: (1 - point.location.y) * overlaySize.height // 坐标系转换，匹配UIKit
                    )
                    context.addArc(center: drawPoint, radius: 8, startAngle: 0, endAngle: .pi*2, clockwise: false)
                    context.fillPath()
                }
                
                // 2. 绘制骨骼（关节枚举配对，无字符串类型错误）
                let bonePairs: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
                    (.leftShoulder, .leftElbow),
                    (.leftElbow, .leftWrist),
                    (.rightShoulder, .rightElbow),
                    (.rightElbow, .rightWrist),
                    (.leftHip, .leftKnee),
                    (.leftKnee, .leftAnkle),
                    (.rightHip, .rightKnee),
                    (.rightKnee, .rightAnkle),
                    (.leftShoulder, .rightShoulder),
                    (.leftHip, .rightHip)
                ]
                
                bonePairs.forEach { fromJoint, toJoint in
                    guard let fromPoint = validKeypoints[fromJoint], let toPoint = validKeypoints[toJoint] else { return }
                    let drawFrom = CGPoint(
                        x: fromPoint.location.x * overlaySize.width,
                        y: (1 - fromPoint.location.y) * overlaySize.height
                    )
                    let drawTo = CGPoint(
                        x: toPoint.location.x * overlaySize.width,
                        y: (1 - toPoint.location.y) * overlaySize.height
                    )
                    
                    context.move(to: drawFrom)
                    context.addLine(to: drawTo)
                    context.strokePath()
                }
            } catch {
                print("叠加层绘制失败：\(error.localizedDescription)")
            }
        }
        
        // 保存叠加层图片，更新UI（主线程，保证流畅无卡顿）
        if let overlayImage = UIGraphicsGetImageFromCurrentImageContext() {
            DispatchQueue.main.async {
                self.poseOverlayImage = overlayImage
            }
        }
        UIGraphicsEndImageContext()
    }
}

//  MARK: - 预览（Xcode模拟器中查看效果）
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

import AVFoundation
import ImageIO
import PhotosUI
import UIKit
import UniformTypeIdentifiers

private enum WalkPhotoImage {
    static let maxSide: CGFloat = 2048

    // 在選圖器的回呼內讀完暫存檔，依拍攝方向縮圖，再建立只有像素的 JPEG。
    static func jpeg(from url: URL) -> Data? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: Int(maxSide)]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let bytes = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(bytes as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.87] as CFDictionary)
        return CGImageDestinationFinalize(output) ? bytes as Data : nil
    }

    static func jpeg(from camera: UIImage) -> Data? {
        let size = camera.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(maxSide / max(size.width, size.height), 1)
        let target = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).jpegData(withCompressionQuality: 0.87) { _ in
            camera.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

final class WalkPhotoCaptureController: UIViewController, PHPickerViewControllerDelegate,
                                        UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private let place: String
    private let save: @MainActor (Data) async throws -> Void
    private let onSaved: @MainActor () -> Void
    private let message = UILabel()
    private let camera = UIButton(type: .system)
    private let library = UIButton(type: .system)
    private let retry = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var selectedPhoto: Data?

    init(place: String, save: @escaping @MainActor (Data) async throws -> Void,
         onSaved: @escaping @MainActor () -> Void) {
        self.place = place
        self.save = save
        self.onSaved = onSaved
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        WalkTheme.paint(view)
        title = place
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(close))
        message.text = "選一張照片，製作這一站的小嚮導透卡。"
        message.font = WalkTheme.kai(19, style: .body)
        message.textColor = WalkTheme.soft
        spinner.color = WalkTheme.ink
        message.adjustsFontForContentSizeCategory = true
        message.textAlignment = .center
        message.numberOfLines = 0
        configure(camera, title: "用相機拍照", icon: "camera", action: #selector(takePhoto))
        configure(library, title: "從相簿選取", icon: "photo.on.rectangle", action: #selector(choosePhoto))
        configure(retry, title: "再試一次", icon: "arrow.clockwise", action: #selector(saveAgain))
        camera.isHidden = !UIImagePickerController.isSourceTypeAvailable(.camera)
        retry.isHidden = true
        let stack = UIStackView(arrangedSubviews: [message, spinner, camera, library, retry])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([stack.centerYAnchor.constraint(equalTo: safe.centerYAnchor),
                                     stack.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 28),
                                     stack.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -28)])
    }

    private func configure(_ button: UIButton, title: String, icon: String, action: Selector) {
        // 拍照是這一頁的主要動作，用金色主按鈕；其他是米白框線。
        let leads = button === camera || (button === library && !UIImagePickerController.isSourceTypeAvailable(.camera))
        WalkTheme.dress(button, leads ? .main : .outline, title: title, image: icon)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func choosePhoto() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    @objc private func takePhoto() {
        Task {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            var allowed = status == .authorized
            if status == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .video) }
            guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
            guard allowed, UIImagePickerController.isSourceTypeAvailable(.camera) else {
                message.text = "相機目前無法使用。你可以從相簿選照片，或在 iPhone 設定裡允許使用相機。"
                return
            }
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.mediaTypes = [UTType.image.identifier]
            picker.delegate = self
            present(picker, animated: true)
        }
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true) { [weak self] in
            guard let self, let provider = results.first?.itemProvider else { return }
            self.setBusy(true)
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                let jpeg = url.flatMap { WalkPhotoImage.jpeg(from: $0) }
                DispatchQueue.main.async { self.receive(jpeg) }
            }
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) }

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        let image = info[.originalImage] as? UIImage
        picker.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            self.setBusy(true)
            DispatchQueue.global(qos: .userInitiated).async {
                let jpeg = image.flatMap { WalkPhotoImage.jpeg(from: $0) }
                DispatchQueue.main.async { self.receive(jpeg) }
            }
        }
    }

    private func setBusy(_ busy: Bool) {
        navigationController?.isModalInPresentation = busy
        navigationItem.leftBarButtonItem?.isEnabled = !busy
        camera.isEnabled = !busy
        library.isEnabled = !busy
        retry.isHidden = busy || selectedPhoto == nil
        if busy {
            message.text = "正在製作並儲存透卡…"
            spinner.startAnimating()
        } else { spinner.stopAnimating() }
    }

    private func receive(_ photo: Data?) {
        selectedPhoto = photo
        guard photo != nil else {
            setBusy(false)
            message.text = "讀不到這張照片。請重新選取，或換一張照片。"
            return
        }
        saveAgain()
    }

    @objc private func saveAgain() {
        guard let selectedPhoto else { return }
        setBusy(true)
        Task {
            do {
                try await save(selectedPhoto)
                dismiss(animated: true, completion: onSaved)
            } catch {
                setBusy(false)
                message.text = "這張照片還沒存好。請再試一次，或換一張照片。"
            }
        }
    }
}

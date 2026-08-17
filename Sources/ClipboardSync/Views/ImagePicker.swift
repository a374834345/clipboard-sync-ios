import SwiftUI
import PhotosUI
import UIKit

/// 相册选图：PHPickerViewController 的 SwiftUI 封装（iOS 14+），不用请求权限。
struct ImagePicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) var dismiss
    /// 用户选完图片后的回调：选到返回 UIImage；取消/失败传 nil
    var onPick: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
        cfg.selectionLimit = 1
        cfg.filter = .images
        let picker = PHPickerViewController(configuration: cfg)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard let first = results.first else { parent.onPick(nil); return }
            let prov = first.itemProvider
            guard prov.canLoadObject(ofClass: UIImage.self) else { parent.onPick(nil); return }
            prov.loadObject(ofClass: UIImage.self) { [weak self] obj, err in
                DispatchQueue.main.async {
                    if let img = obj as? UIImage {
                        self?.parent.onPick(img)
                    } else {
                        self?.parent.onPick(nil)
                    }
                }
            }
        }
    }
}

/// 相机拍照：UIImagePickerController 的 SwiftUI 封装（sourceType = .camera）
struct CameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) var dismiss
    var onPick: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.allowsEditing = true
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let maybe = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
            parent.dismiss()
            parent.onPick(maybe)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
            parent.onPick(nil)
        }
    }
}

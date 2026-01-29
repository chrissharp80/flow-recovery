//
//  Copyright © 2024-2026 Chris Sharp. All rights reserved.
//
//  This source code is provided for reference and verification purposes only.
//  Unauthorized copying, modification, distribution, or use of this code,
//  via any medium, is strictly prohibited without prior written permission.
//
//  For licensing inquiries, contact the copyright holder.
//

import SwiftUI
import UIKit
import QuickLook

/// Text file preview with share functionality (uses QuickLook like PDFPreviewView)
struct TextFilePreviewView: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let previewController = QLPreviewController()
        previewController.dataSource = context.coordinator
        previewController.delegate = context.coordinator

        let navController = UINavigationController(rootViewController: previewController)

        // Add Done button to dismiss
        let doneButton = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: context.coordinator,
            action: #selector(Coordinator.doneAction)
        )
        previewController.navigationItem.leftBarButtonItem = doneButton

        // Add share button to navigation bar
        let shareButton = UIBarButtonItem(
            barButtonSystemItem: .action,
            target: context.coordinator,
            action: #selector(Coordinator.shareAction)
        )
        previewController.navigationItem.rightBarButtonItem = shareButton

        return navController
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let parent: TextFilePreviewView

        init(parent: TextFilePreviewView) {
            self.parent = parent
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            return 1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            return parent.url as QLPreviewItem
        }

        @objc func doneAction() {
            parent.dismiss()
        }

        @objc func shareAction() {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let viewController = windowScene.windows.first?.rootViewController else { return }

            let activityVC = UIActivityViewController(
                activityItems: [parent.url],
                applicationActivities: nil
            )

            // iPad popover setup
            if let popover = activityVC.popoverPresentationController {
                popover.barButtonItem = viewController.navigationItem.rightBarButtonItem
            }

            viewController.present(activityVC, animated: true)
        }
    }
}

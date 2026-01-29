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
import QuickLook
import UIKit

/// QLPreviewController wrapper for PDF preview with share option
struct PDFPreviewView: UIViewControllerRepresentable {
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
        let parent: PDFPreviewView

        init(parent: PDFPreviewView) {
            self.parent = parent
        }

        // MARK: - QLPreviewControllerDataSource

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            return 1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            return parent.url as QLPreviewItem
        }

        // MARK: - QLPreviewControllerDelegate

        func previewControllerDidDismiss(_ controller: QLPreviewController) {
            parent.dismiss()
        }

        // MARK: - Actions

        @objc func doneAction() {
            parent.dismiss()
        }

        @objc func shareAction() {
            let activityVC = UIActivityViewController(
                activityItems: [parent.url],
                applicationActivities: nil
            )

            // Find the topmost view controller to present from
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                var topVC = rootVC
                while let presentedVC = topVC.presentedViewController {
                    topVC = presentedVC
                }
                activityVC.popoverPresentationController?.sourceView = topVC.view
                activityVC.popoverPresentationController?.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
                topVC.present(activityVC, animated: true)
            }
        }
    }
}

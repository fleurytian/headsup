import UserNotifications

/// Modifies inbound APNs payload before iOS displays the banner.
/// Downloads `image_url` (if present) and attaches it as a UNNotificationAttachment
/// so the user sees the image in the expanded notification.
final class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

        guard let bestAttempt = bestAttemptContent else {
            contentHandler(request.content)
            return
        }

        guard let imageUrlString = bestAttempt.userInfo["image_url"] as? String,
              let imageUrl = URL(string: imageUrlString) else {
            contentHandler(bestAttempt)
            return
        }

        // 5-second budget; iOS will deliver the unmodified notification if NSE takes longer
        downloadAndAttach(url: imageUrl) { attachment in
            if let attachment = attachment {
                bestAttempt.attachments = [attachment]
            }
            contentHandler(bestAttempt)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler = contentHandler, let content = bestAttemptContent {
            handler(content)
        }
    }

    private func downloadAndAttach(url: URL, completion: @escaping (UNNotificationAttachment?) -> Void) {
        URLSession.shared.downloadTask(with: url) { tempUrl, response, error in
            guard let tempUrl = tempUrl, error == nil else {
                completion(nil); return
            }
            // Move to a unique extension matching the content type so iOS can render it
            let ext = (response?.mimeType?.split(separator: "/").last).map(String.init) ?? "jpg"
            let safeExt = ["jpeg", "jpg", "png", "gif", "heic"].contains(ext.lowercased()) ? ext : "jpg"
            let dst = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString + "." + safeExt)
            do {
                try FileManager.default.moveItem(at: tempUrl, to: dst)
                let attachment = try UNNotificationAttachment(identifier: "image", url: dst, options: nil)
                completion(attachment)
            } catch {
                completion(nil)
            }
        }.resume()
    }
}

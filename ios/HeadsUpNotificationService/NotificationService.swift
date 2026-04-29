import UserNotifications
import Intents

/// Modifies inbound APNs payload before iOS displays the banner.
///
/// Two upgrades over a plain banner:
/// 1. Downloads `image_url` and attaches it as a UNNotificationAttachment so
///    the user sees the image in the expanded notification.
/// 2. If the payload carries `agent_name` + `image_url`, converts the
///    notification to a **Communication Notification** (iOS 15+) so the
///    banner renders with the agent as a large sender avatar at the top —
///    like an iMessage. Without this, iOS shows the host app icon (HeadsUp)
///    on the left and the attachment as a small right-side thumbnail.
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

        let info = bestAttempt.userInfo
        let imageUrlString = info["image_url"] as? String
        let agentName = info["agent_name"] as? String
        let agentId = info["agent_id"] as? String

        guard let imageUrlString, let imageUrl = URL(string: imageUrlString) else {
            // No image at all — try to make it a communication notification using
            // just the agent name (no avatar). On iOS 15+ this still bumps the layout.
            contentHandler(makeCommunication(bestAttempt, agentName: agentName, agentId: agentId, image: nil) ?? bestAttempt)
            return
        }

        // 5-second budget; iOS will deliver the unmodified notification if NSE takes longer.
        downloadAndAttach(url: imageUrl) { [weak self] attachment, downloadedFile in
            guard let self else { contentHandler(bestAttempt); return }
            if let attachment {
                bestAttempt.attachments = [attachment]
            }
            // Try to upgrade to a communication notification using the downloaded image.
            let avatar: INImage?
            if let downloadedFile, let data = try? Data(contentsOf: downloadedFile) {
                avatar = INImage(imageData: data)
            } else {
                avatar = nil
            }
            let upgraded = self.makeCommunication(bestAttempt, agentName: agentName, agentId: agentId, image: avatar)
            contentHandler(upgraded ?? bestAttempt)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler = contentHandler, let content = bestAttemptContent {
            handler(content)
        }
    }

    /// Build an INSendMessageIntent + donate it, then return the content updated
    /// from that intent. Returns nil if the intent path can't run (older iOS,
    /// missing agent name) — caller falls back to the raw bestAttempt.
    private func makeCommunication(
        _ content: UNMutableNotificationContent,
        agentName: String?,
        agentId: String?,
        image: INImage?
    ) -> UNNotificationContent? {
        guard #available(iOS 15.0, *) else { return nil }
        guard let agentName = agentName, !agentName.isEmpty else { return nil }

        let handle = INPersonHandle(value: agentId ?? agentName, type: .unknown)
        let person = INPerson(
            personHandle: handle,
            nameComponents: nil,
            displayName: agentName,
            image: image,
            contactIdentifier: nil,
            customIdentifier: agentId
        )

        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: content.body,
            speakableGroupName: nil,
            conversationIdentifier: agentId ?? agentName,
            serviceName: "HeadsUp",
            sender: person,
            attachments: nil
        )
        if let image { intent.setImage(image, forParameterNamed: \.sender) }

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)

        do {
            return try content.updating(from: intent)
        } catch {
            return nil
        }
    }

    private func downloadAndAttach(
        url: URL,
        completion: @escaping (UNNotificationAttachment?, URL?) -> Void
    ) {
        URLSession.shared.downloadTask(with: url) { tempUrl, response, error in
            guard let tempUrl = tempUrl, error == nil else {
                completion(nil, nil); return
            }
            let ext = (response?.mimeType?.split(separator: "/").last).map(String.init) ?? "jpg"
            let safeExt = ["jpeg", "jpg", "png", "gif", "heic"].contains(ext.lowercased()) ? ext : "jpg"
            let dst = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString + "." + safeExt)
            do {
                try FileManager.default.moveItem(at: tempUrl, to: dst)
                let attachment = try UNNotificationAttachment(identifier: "image", url: dst, options: nil)
                completion(attachment, dst)
            } catch {
                completion(nil, nil)
            }
        }.resume()
    }
}

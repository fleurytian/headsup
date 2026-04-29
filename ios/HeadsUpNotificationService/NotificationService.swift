import UserNotifications
import Intents

/// Two distinct images live in the payload:
///
/// - `agent_avatar_url`  — always present. Becomes the sender's face on a
///                         Communication Notification (iOS 15+). Replaces
///                         what would otherwise be the host app icon on the
///                         left of the banner.
///
/// - `image_url`         — optional, agent-controlled. Becomes the regular
///                         right-side thumbnail / hero image inside the
///                         expanded notification.
///
/// We download both in parallel, attach `image_url` (if any) as the
/// notification attachment, and hand `agent_avatar_url` to
/// INSendMessageIntent so iOS renders the comm-notification layout.
final class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    private var didFinish = false

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
        let avatarUrlString = info["agent_avatar_url"] as? String
        let agentName = info["agent_name"] as? String
        let agentId = info["agent_id"] as? String

        let group = DispatchGroup()
        var imageFile: URL? = nil
        var avatarFile: URL? = nil
        var avatarImage: INImage? = nil

        if let imageUrlString, let url = URL(string: imageUrlString) {
            group.enter()
            downloadFile(url: url) { localUrl in
                imageFile = localUrl
                group.leave()
            }
        }
        if let avatarUrlString, let url = URL(string: avatarUrlString) {
            group.enter()
            downloadFile(url: url) { localUrl in
                avatarFile = localUrl
                if let localUrl, let data = try? Data(contentsOf: localUrl) {
                    avatarImage = INImage(imageData: data)
                }
                group.leave()
            }
        }

        let finalize = { [weak self] in
            guard let self, !self.didFinish else { return }
            self.didFinish = true

            // Right-side thumbnail: the per-message image_url if the agent set
            // one, otherwise the avatar (so a notification ALWAYS has visible
            // identity even without the comm-notification entitlement).
            let attachmentSource = imageFile ?? avatarFile
            if let src = attachmentSource,
               let att = try? UNNotificationAttachment(identifier: "image", url: src, options: nil) {
                bestAttempt.attachments = [att]
            }

            // Try to upgrade to a Communication Notification. Falls back
            // silently to the regular banner if Apple's comm-notification
            // entitlement isn't granted on this build.
            let upgraded = self.makeCommunication(
                bestAttempt, agentName: agentName, agentId: agentId, image: avatarImage
            )
            contentHandler(upgraded ?? bestAttempt)
        }

        group.notify(queue: .main) { finalize() }
        // Hard timeout — iOS kills NSE after ~30s but we want to ship before
        // the user notices the extra delay. Whichever fires first wins;
        // didFinish guards against the loser firing after.
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(5)) { finalize() }
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler = contentHandler, let content = bestAttemptContent {
            handler(content)
        }
    }

    /// Build an INSendMessageIntent + donate it, then return the content
    /// updated from that intent. nil if conversion isn't possible (older iOS,
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
        return try? content.updating(from: intent)
    }

    /// Download to a unique tmp file with the right extension. Returns nil on failure.
    private func downloadFile(url: URL, completion: @escaping (URL?) -> Void) {
        URLSession.shared.downloadTask(with: url) { tempUrl, response, error in
            guard let tempUrl, error == nil else { completion(nil); return }
            let mime = response?.mimeType?.split(separator: "/").last.map(String.init) ?? "jpg"
            let safe = ["jpeg", "jpg", "png", "gif", "heic"].contains(mime.lowercased()) ? mime : "jpg"
            let dst = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString + "." + safe)
            do {
                try FileManager.default.moveItem(at: tempUrl, to: dst)
                completion(dst)
            } catch {
                completion(nil)
            }
        }.resume()
    }
}

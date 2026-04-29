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
    /// updated from that intent. Mirrors Bark's IconProcessor pattern (which
    /// does NOT need the com.apple.developer.usernotifications.communication
    /// entitlement to render the sender avatar):
    ///   - nickname = title (so the sender label shows the agent name)
    ///   - two recipients required for subtitle to render — Apple bug
    ///   - avatar attached via \.speakableGroupName, NOT \.sender
    private func makeCommunication(
        _ content: UNMutableNotificationContent,
        agentName: String?,
        agentId: String?,
        image: INImage?
    ) -> UNNotificationContent? {
        guard #available(iOSApplicationExtension 15.0, *) else { return nil }
        guard let image else { return nil }   // no avatar = nothing to show

        var nameComponents = PersonNameComponents()
        // The "sender name" iOS renders next to the avatar. Prefer agent name,
        // fall back to the notification title.
        nameComponents.nickname = (agentName?.isEmpty == false ? agentName : content.title) ?? "Agent"

        let avatar = image
        let senderPerson = INPerson(
            personHandle: INPersonHandle(value: agentId ?? "", type: .unknown),
            nameComponents: nameComponents,
            displayName: nameComponents.nickname,
            image: avatar,
            contactIdentifier: nil,
            customIdentifier: agentId,
            isMe: false,
            suggestionType: .none
        )
        let mePerson = INPerson(
            personHandle: INPersonHandle(value: "", type: .unknown),
            nameComponents: nil,
            displayName: nil,
            image: nil,
            contactIdentifier: nil,
            customIdentifier: nil,
            isMe: true,
            suggestionType: .none
        )
        // Apple bug: you need TWO non-me recipients (or self+other) for the
        // subtitle to render in the comm-notification layout. Bark figured
        // this out — keep both.
        let placeholderPerson = INPerson(
            personHandle: INPersonHandle(value: "", type: .unknown),
            nameComponents: nameComponents,
            displayName: nameComponents.nickname,
            image: avatar,
            contactIdentifier: nil,
            customIdentifier: nil
        )

        let intent = INSendMessageIntent(
            recipients: [mePerson, placeholderPerson],
            outgoingMessageType: .outgoingMessageText,
            content: content.body,
            speakableGroupName: INSpeakableString(spokenPhrase: content.subtitle),
            conversationIdentifier: content.threadIdentifier,
            serviceName: nil,
            sender: senderPerson,
            attachments: nil
        )
        // \.speakableGroupName is the right key — \.sender does NOT bind the
        // avatar to the rendered banner.
        intent.setImage(avatar, forParameterNamed: \.speakableGroupName)

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)
        return try? content.updating(from: intent) as? UNMutableNotificationContent
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

import Cocoa
import UserNotifications
import FirebaseCore
import FirebaseMessaging
import Network

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate {
    
    // MARK: - UI Properties
    private var window: NSWindow!
    private var statusLabel: NSTextField!
    private var connectionStatusLabel: NSTextField!
    private var apnsTokenLabel: NSTextField!
    private var fcmTokenLabel: NSTextField!
    private var logTextView: NSTextView!
    
    // MARK: - State Management
    private var lastNotificationTime: Date?
    private var lastSuccessfulRegistration: Date?
    private var registrationRetryCount = 0
    private var isRegistrationInProgress = false
    
    // MARK: - Monitoring
    private var healthCheckTimer: Timer?
    private var registrationTimeoutTimer: Timer?
    private let networkMonitor = NWPathMonitor()
    private var activityToken: NSObjectProtocol?
    
    // MARK: - Lifecycle
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        setupBackgroundActivity()
        setupFirebase()
        setupWindow()
        setupDelegates()
        requestNotificationPermissions()
        startMonitoring()
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        cleanup()
    }
    
    // MARK: - Setup
    
    private func setupBackgroundActivity() {
        let options: ProcessInfo.ActivityOptions = [
            .background,
            .suddenTerminationDisabled,
            .automaticTerminationDisabled
        ]
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: options,
            reason: "Push notification maintenance"
        )
    }
    
    private func setupFirebase() {
        FirebaseApp.configure()
        log("Firebase configured")
    }
    
    private func setupDelegates() {
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self
        log("Delegates configured")
    }
    
    private func setupWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 550),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "APNS + FCM Demo"
        window.center()
        
        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        
        let titleLabel = NSTextField(labelWithString: "macOS Push Notifications Demo")
        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        titleLabel.frame = NSRect(x: 20, y: 490, width: 660, height: 30)
        contentView.addSubview(titleLabel)
        
        statusLabel = NSTextField(labelWithString: "Status: Initializing...")
        statusLabel.frame = NSRect(x: 20, y: 460, width: 660, height: 20)
        contentView.addSubview(statusLabel)
        
        connectionStatusLabel = NSTextField(labelWithString: "Connection: Checking...")
        connectionStatusLabel.frame = NSRect(x: 20, y: 435, width: 660, height: 20)
        connectionStatusLabel.textColor = .secondaryLabelColor
        contentView.addSubview(connectionStatusLabel)
        
        let apnsTitle = NSTextField(labelWithString: "APNS Device Token:")
        apnsTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        apnsTitle.frame = NSRect(x: 20, y: 405, width: 660, height: 20)
        contentView.addSubview(apnsTitle)
        
        apnsTokenLabel = NSTextField(wrappingLabelWithString: "Waiting...")
        apnsTokenLabel.frame = NSRect(x: 20, y: 370, width: 660, height: 35)
        apnsTokenLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        apnsTokenLabel.textColor = .secondaryLabelColor
        contentView.addSubview(apnsTokenLabel)
        
        let fcmTitle = NSTextField(labelWithString: "FCM Registration Token:")
        fcmTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        fcmTitle.frame = NSRect(x: 20, y: 340, width: 660, height: 20)
        contentView.addSubview(fcmTitle)
        
        fcmTokenLabel = NSTextField(wrappingLabelWithString: "Waiting...")
        fcmTokenLabel.frame = NSRect(x: 20, y: 305, width: 660, height: 35)
        fcmTokenLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        fcmTokenLabel.textColor = .secondaryLabelColor
        contentView.addSubview(fcmTokenLabel)
        
        let buttonY = 265
        let copyAPNS = createButton("Copy APNS", x: 20, y: buttonY, action: #selector(copyAPNSToken))
        let copyFCM = createButton("Copy FCM", x: 180, y: buttonY, action: #selector(copyFCMToken))
        let reconnect = createButton("Reconnect APNS", x: 340, y: buttonY, action: #selector(reconnectAPNS))
        let clearLog = createButton("Clear Logs", x: 540, y: buttonY, action: #selector(clearLogs))
        
        [copyAPNS, copyFCM, reconnect, clearLog].forEach { contentView.addSubview($0) }
        
        let logTitle = NSTextField(labelWithString: "Event Log:")
        logTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        logTitle.frame = NSRect(x: 20, y: 235, width: 660, height: 20)
        contentView.addSubview(logTitle)
        
        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 20, width: 660, height: 205))
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]
        scrollView.borderType = .bezelBorder
        
        logTextView = NSTextView(frame: scrollView.bounds)
        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logTextView.autoresizingMask = [.width]
        logTextView.textContainer?.widthTracksTextView = true
        
        scrollView.documentView = logTextView
        contentView.addSubview(scrollView)
        
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
    }
    
    private func createButton(_ title: String, x: Int, y: Int, action: Selector) -> NSButton {
        let button = NSButton(frame: NSRect(x: x, y: y, width: 150, height: 32))
        button.title = title
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        return button
    }
    
    // MARK: - Permissions
    private func requestNotificationPermissions() {
        log("Requesting notification permissions")
        
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if granted {
                    self.statusLabel.stringValue = "Status: Authorized"
                    self.log("Permissions granted")
                    self.registerForAPNS()
                } else {
                    self.statusLabel.stringValue = "Status: Denied"
                    self.log("Permissions denied")
                }
                
                if let error = error {
                    self.log("Permission error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - Registration
    private func registerForAPNS() {
        guard !isRegistrationInProgress else {
            log("Registration already in progress")
            return
        }
        
        isRegistrationInProgress = true
        startRegistrationTimeout()
        
        log("Registering for remote notifications")
        NSApplication.shared.registerForRemoteNotifications()
    }
    
    @objc private func reconnectAPNS() {
        guard !isRegistrationInProgress else {
            log("Registration already in progress")
            return
        }
        
        log("Reconnecting APNS")
        isRegistrationInProgress = true
        
        DispatchQueue.main.async {
            NSApplication.shared.unregisterForRemoteNotifications()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.startRegistrationTimeout()
                NSApplication.shared.registerForRemoteNotifications()
            }
        }
    }
    
    private func startRegistrationTimeout() {
        registrationTimeoutTimer?.invalidate()
        registrationTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            guard let self = self, self.isRegistrationInProgress else { return }
            
            self.log("Registration timeout (30s)")
            self.isRegistrationInProgress = false
            
            if self.registrationRetryCount < 3 {
                let delay = TimeInterval(pow(2.0, Double(self.registrationRetryCount))) * 5.0
                self.log("Retrying in \(Int(delay))s")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.reconnectAPNS()
                }
            }
        }
    }
    

    // MARK: - Monitoring
    private func startMonitoring() {
        setupHealthCheckTimer()
        startNetworkMonitoring()
        observeSystemEvents()
    }
    
    private func setupHealthCheckTimer() {
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 60 * 15, repeats: true) { [weak self] _ in
            self?.performHealthCheck()
        }
    }
    
    private func performHealthCheck() {
        log("Health check")
        
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            guard let self = self else { return }
            
            if settings.authorizationStatus != .authorized {
                self.log("Not authorized")
                return
            }
            
            if !NSApplication.shared.isRegisteredForRemoteNotifications {
                self.log("Not registered, reconnecting")
                self.reconnectAPNS()
                return
            }
            
            if let lastReceived = self.lastNotificationTime,
               Date().timeIntervalSince(lastReceived) > 3600 {
                self.log("No notifications >1h, refreshing")
                self.checkAndRefreshRegistration()
            }
        }
    }
    
    private func checkAndRefreshRegistration() {
        if registrationRetryCount >= 3 {
            log("Max retries reached, waiting 1h")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3600) { [weak self] in
                self?.registrationRetryCount = 0
                self?.reconnectAPNS()
            }
            return
        }
        
        log("Refreshing registration (attempt \(registrationRetryCount + 1))")
        registrationRetryCount += 1
        registerForAPNS()
    }
    
    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            
            if path.status == .satisfied {
                self.log("Network available")
                self.updateConnectionStatus("Connected", color: .systemGreen)
                
                if self.lastSuccessfulRegistration == nil {
                    self.reconnectAPNS()
                }
            } else {
                self.log("Network unavailable")
                self.updateConnectionStatus("Network unavailable", color: .systemRed)
            }
        }
        networkMonitor.start(queue: .global(qos: .background))
    }
    
    private func observeSystemEvents() {
        let distributedCenter = DistributedNotificationCenter.default()
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        let notifications: [(NotificationCenter, NSNotification.Name)] = [
            (distributedCenter, NSNotification.Name("com.apple.apsd.launched")),
            (distributedCenter, NSNotification.Name("com.apple.usernoted.launch")),
            (distributedCenter, NSNotification.Name("com.apple.notificationcenter.launch")),
            (workspaceCenter, NSWorkspace.screensDidSleepNotification),
            (workspaceCenter, NSWorkspace.screensDidSleepNotification),
            (workspaceCenter, NSWorkspace.sessionDidBecomeActiveNotification),
            (workspaceCenter, NSWorkspace.didWakeNotification),
            (distributedCenter, NSNotification.Name("com.apple.screenIsUnlocked")),
            (distributedCenter, NSNotification.Name("com.apple.screenIsLocked"))
        ]

        for (center, name) in notifications {
            center.addObserver(self, selector: #selector(handleSystemNotification(_:)), name: name, object: nil)
        }
    }
    
    @objc private func handleSystemNotification(_ notification: Notification) {
        log("System event: \(notification.name.rawValue)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.reconnectAPNS()
        }
    }
    
    private func updateConnectionStatus(_ status: String, color: NSColor) {
        DispatchQueue.main.async {
            self.connectionStatusLabel.stringValue = "Connection: \(status)"
            self.connectionStatusLabel.textColor = color
        }
    }
    

    // MARK: - APNS Delegate
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        registrationTimeoutTimer?.invalidate()
        isRegistrationInProgress = false
        registrationRetryCount = 0
        lastSuccessfulRegistration = Date()
        
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        log("APNS token: \(token)")
        
        DispatchQueue.main.async {
            self.apnsTokenLabel.stringValue = token
        }
        
        Messaging.messaging().apnsToken = deviceToken
    }
    
    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        registrationTimeoutTimer?.invalidate()
        isRegistrationInProgress = false
        
        log("APNS registration failed: \(error.localizedDescription)")
        
        DispatchQueue.main.async {
            self.apnsTokenLabel.stringValue = "Failed: \(error.localizedDescription)"
            self.statusLabel.stringValue = "Status: Registration failed"
        }
        
        let retryDelay = TimeInterval(pow(2.0, Double(registrationRetryCount))) * 5.0
        if registrationRetryCount < 3 {
            log("Retry in \(Int(retryDelay))s (attempt \(registrationRetryCount + 1)/3)")
            registrationRetryCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                self?.reconnectAPNS()
            }
        }
    }
    
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        lastNotificationTime = Date()
        log("Remote notification received: \(userInfo)")
        
        if let aps = userInfo["aps"] as? [String: Any],
           let contentAvailable = aps["content-available"] as? Int,
           contentAvailable == 1 {
            log("Background notification")
        }
    }

    
    // MARK: - FCM Delegate
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken else {
            log("FCM token is nil")
            return
        }
        
        log("FCM token: \(token.prefix(10))...\(token.suffix(10))")
        
        DispatchQueue.main.async {
            self.fcmTokenLabel.stringValue = token
        }
    }
    

    // MARK: - UNUserNotificationCenter Delegate
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        lastNotificationTime = Date()
        log("Foreground notification: \(notification.request.content.title)")
        completionHandler([.banner, .sound, .badge])
    }
    
    // MARK: - UI Actions
    @objc private func copyAPNSToken() {
        let token = apnsTokenLabel.stringValue
        guard !token.contains("Waiting") && !token.contains("Failed") else { return }
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
        log("APNS token copied")
    }
    
    @objc private func copyFCMToken() {
        let token = fcmTokenLabel.stringValue
        guard !token.contains("Waiting") && !token.contains("Failed") else { return }
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
        log("FCM token copied")
    }
    
    @objc private func clearLogs() {
        logTextView.string = ""
        log("Logs cleared")
    }

    
    // MARK: - Logging
    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logMessage = "[\(timestamp)] \(message)\n"
        
        DispatchQueue.main.async {
            self.logTextView.textStorage?.append(NSAttributedString(string: logMessage))
            self.logTextView.scrollToEndOfDocument(nil)
        }
        
        print(logMessage)
    }
    
    // MARK: - Cleanup
    private func cleanup() {
        log("Cleaning up")
        
        healthCheckTimer?.invalidate()
        registrationTimeoutTimer?.invalidate()
        networkMonitor.cancel()
        
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
        }
        
        NSApplication.shared.unregisterForRemoteNotifications()
        Messaging.messaging().delegate = nil
        UNUserNotificationCenter.current().delegate = nil
    }
}

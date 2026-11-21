import SwiftUI

struct IPASigningSetupPage: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var state: IPASigningState
    @ObservedObject private var renewal = IPARenewalManager.shared
    @ObservedObject private var installer = IPAInstallCoordinator.shared
    var body: some View {
        Group {
            #if IPASTORE_PREVIEW
            IPAEmptyState(title: "Signing Setup", subtitle: "Account and device pairing setup is available in the complete iPhone build.", symbol: "checkmark.shield")
            #else
            if renewal.working || installer.busy {
                IPAEmptyState(title: "Signing in Progress", subtitle: "Let signing finish before changing your setup.", symbol: "clock")
            } else if !state.serviceAvailable || !state.capabilitiesReady {
                IPAEmptyState(title: "Complete Build Required", subtitle: "Install iPAStore with all its app extensions retained to use signing setup.", symbol: "checkmark.shield")
            } else {
                IPAInteractiveSigningScene(state: state) { dismiss() }.ignoresSafeArea()
                    .toolbar(.hidden, for: .navigationBar, .tabBar)
            }
            #endif
        }.background(IPAStyle.canvas).navigationTitle("Signing Setup").navigationBarTitleDisplayMode(.inline)
            .onAppear { UserDefaults.standard.set(true, forKey: "IPASigningSetupOpen") }
            .onDisappear { UserDefaults.standard.set(false, forKey: "IPASigningSetupOpen"); state.importInteractiveReadiness(allowCertificateImport: true) }
    }
}

#if !IPASTORE_PREVIEW
private struct IPAInteractiveSigningScene: UIViewControllerRepresentable {
    let state: IPASigningState
    let done: () -> Void
    func makeUIViewController(context: Context) -> IPAInteractiveSigningController { IPAInteractiveSigningController(state: state, done: done) }
    func updateUIViewController(_ controller: IPAInteractiveSigningController, context: Context) {}
    static func dismantleUIViewController(_ controller: IPAInteractiveSigningController, coordinator: ()) { controller.stop() }
}

// Hosts the signing UI in its existing isolated process, without restarting
// iPAStore or loading guest bundle/keychain hooks into the storefront process.
private final class IPAInteractiveSigningController: UIViewController, AppSceneViewControllerDelegate {
    private static let timingQueue = DispatchQueue(label: "app.ipastore.signing-startup", qos: .utility)
    private let createdAt = CACurrentMediaTime()
    private let done: () -> Void
    private let state: IPASigningState
    private var lastFrame = CGRect.null
    private var lastInsets = UIEdgeInsets.zero
    private var scene: AppSceneViewController?
    private var stopped = false
    private var activated = false
    private let message = UILabel()
    private let cancel = UIButton(type: .system)
    init(state: IPASigningState, done: @escaping () -> Void) { self.state = state; self.done = done; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        message.isHidden = true; message.textColor = .secondaryLabel; message.textAlignment = .center; message.numberOfLines = 0
        message.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(message)
        cancel.setTitle("Back", for: .normal); cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.addTarget(self, action: #selector(close), for: .touchUpInside); view.addSubview(cancel)
        NSLayoutConstraint.activate([
            message.centerYAnchor.constraint(equalTo: view.centerYAnchor), message.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24), message.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            cancel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8), cancel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20), cancel.heightAnchor.constraint(equalToConstant: 44)
        ])
        // Load the isolated signing view without presenting a second setup page.
        DispatchQueue.main.async { [weak self] in self?.startSigning() }
    }
    private func startSigning() {
        guard !stopped, scene == nil else { return }
        let child = AppSceneViewController(bundleId: "builtinSideStore", dataUUID: "IPAStoreSigningSetup", delegate: self)
        guard let child else { showFailure("Signing setup couldn’t start. Go back and try again."); return }
        scene = child; addChild(child); child.view.frame = view.bounds; child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        child.view.alpha = 0
        view.insertSubview(child.view, at: 0); child.didMove(toParent: self); view.setNeedsLayout()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !self.stopped, !self.activated else { return }
            self.showFailure("Signing setup couldn’t start. Go back and try again.")
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let scene, lastFrame != view.bounds || lastInsets != view.safeAreaInsets else { return }
        lastFrame = view.bounds; lastInsets = view.safeAreaInsets
        scene.view.frame = view.bounds
        scene.updateFrame { [weak self] settings in
            guard let self, let settings else { return }
            settings.setFrame(self.view.bounds)
            settings.safeAreaInsetsPortrait = self.view.safeAreaInsets
            settings.peripheryInsets = self.view.safeAreaInsets
        }
    }
    func appSceneVCWillActivateScene(_ vc: AppSceneViewController!) {
        guard !stopped else { return }
        vc.updateSettings { [weak self] settings in
            guard let self, let settings else { return }
            settings.setValue(false, forKey: "statusBarDisabled")
            settings.safeAreaInsetsPortrait = self.view.safeAreaInsets
            settings.peripheryInsets = self.view.safeAreaInsets
            settings.setFrame(self.view.bounds)
        }
    }
    func appSceneVCDidAttachContent(_ vc: AppSceneViewController!) {
        guard !stopped else { return }
        activated = true; lastFrame = .null
        recordStartupTiming("ready")
        view.setNeedsLayout()
        message.isHidden = true; cancel.isHidden = true
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.18) { vc.view.alpha = 1 }
    }
    private func recordStartupTiming(_ phase: String) {
        guard let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("iPAStoreSigningSetupTiming.json"),
              let data = try? JSONSerialization.data(withJSONObject: ["phase": phase, "elapsedMilliseconds": Int((CACurrentMediaTime() - createdAt) * 1000)]) else { return }
        Self.timingQueue.async { try? data.write(to: file, options: .atomic) }
    }
    private func showFailure(_ text: String) {
        recordStartupTiming("failed")
        scene?.view.alpha = 0
        message.text = text; message.isHidden = false; cancel.isHidden = false
    }
    func appSceneVC(_ vc: AppSceneViewController!, didInitializeWithError error: (any Error)!) {
        guard !stopped else { return }
        if error != nil { showFailure("Signing setup couldn’t start. Go back and try again.") }
    }
    func appSceneVCAppDidExit(_ vc: AppSceneViewController!) {
        guard !stopped else { return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let returned = documents.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("SideStore/Documents/IPAStoreSetupStatus.plist").path) } ?? false
        stop()
        if returned { done() }
        else {
            showFailure("Signing setup closed before finishing. Your installed apps are still here. Go back and try again. If it happens when opening the VPN, open LocalDevVPN from the Home Screen first, connect it, then return to setup.")
        }
    }
    @objc private func close() { stop(); done() }
    func stop() {
        guard !stopped else { return }
        stopped = true
        scene?.terminate()
        scene?.willMove(toParent: nil); scene?.view.removeFromSuperview(); scene?.removeFromParent(); scene = nil
    }
}

#endif

//
//  AuthenticationViewController.swift
//  AltStore
//
//  Created by Riley Testut on 9/5/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit

import SideSign

final class AuthenticationViewController: UIViewController
{
    var authenticationHandler: ((String, String, @escaping (Result<(ALTAccount, ALTAppleAPISession), Error>) -> Void) -> Void)?
    var completionHandler: (((ALTAccount, ALTAppleAPISession, String)?) -> Void)?
    
    private weak var toastView: ToastView?
    
    @IBOutlet private var appleIDTextField: UITextField!
    @IBOutlet private var passwordTextField: UITextField!
    @IBOutlet private var signInButton: UIButton!
    
    @IBOutlet private var appleIDBackgroundView: UIView!
    @IBOutlet private var passwordBackgroundView: UIView!
    
    @IBOutlet private var scrollView: UIScrollView!
    @IBOutlet private var contentStackView: UIStackView!
    
    private var iPAStoreInteractive: Bool { getenv("IPA_SIGNING_INTERACTIVE") != nil }
    private var iPAStoreAccent: UIColor {
        let hex = ProcessInfo.processInfo.environment["IPA_SIGNING_ACCENT"] ?? "007AFF"
        guard let value = UInt32(hex, radix: 16), hex.uppercased() != "007AFF" else { return .systemBlue }
        return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard iPAStoreInteractive else { return }
        navigationItem.title = nil
        navigationItem.largeTitleDisplayMode = .never
        if let bar = navigationController?.navigationBar {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithDefaultBackground()
            appearance.titleTextAttributes = [.foregroundColor: UIColor.label]
            bar.barStyle = .default
            bar.tintColor = .label
            bar.standardAppearance = appearance
            bar.compactAppearance = appearance
            bar.scrollEdgeAppearance = appearance
        }
    }

    override func viewDidLoad()
    {
        super.viewDidLoad()

        if iPAStoreInteractive {
            let canvas = UIColor { traits in
                traits.userInterfaceStyle == .dark ? .systemBackground : UIColor(red: 0.98, green: 0.977, blue: 0.968, alpha: 1)
            }
            self.view.backgroundColor = canvas
            let accent = iPAStoreAccent
            self.scrollView.keyboardDismissMode = .interactive
            self.scrollView.indicatorStyle = .default
            self.view.tintColor = accent
            func style(_ view: UIView) {
                if let label = view as? UILabel { label.textColor = .label }
                for child in view.subviews { style(child) }
            }
            style(self.view)
            self.appleIDBackgroundView.backgroundColor = .secondarySystemGroupedBackground
            self.passwordBackgroundView.backgroundColor = .secondarySystemGroupedBackground
            for field in [self.appleIDTextField!, self.passwordTextField!] {
                field.textColor = .label; field.tintColor = accent
                if let placeholder = field.placeholder { field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: UIColor.secondaryLabel]) }
            }
            self.signInButton.backgroundColor = .secondarySystemFill
            self.signInButton.setTitleColor(accent, for: .normal)
        }
        
        // fetch anisette servers asap when loading Auth Screen (if list is empty)
        Task {
            if await AnisetteServersManager.shared.getActiveServerURLs().isEmpty {
                let sourceURL = UserDefaults.standard.menuAnisetteList
                do {
                    _ = try await AnisetteServersManager.shared.syncWithRemote(sourceURLString: sourceURL, forceRemote: true)
                    debugLog("AuthenticationViewController: Server list refresh request completed for sourceURL: \(sourceURL)")
                } catch {
                    debugLog("AuthenticationViewController: Server list refresh request Failed for sourceURL: \(sourceURL) Error: \(error)")
                }
            }
        }
        
        self.signInButton.activityIndicatorView.style = .medium
        self.signInButton.activityIndicatorView.color = iPAStoreInteractive ? iPAStoreAccent : .white
        
        for view in [self.appleIDBackgroundView!, self.passwordBackgroundView!, self.signInButton!]
        {
            #if !os(tvOS)
            view.clipsToBounds = true
            #endif
            view.layer.cornerRadius = 16
        }

        self.appleIDTextField.autocapitalizationType = .none
        self.appleIDTextField.autocorrectionType = .no
        self.appleIDTextField.spellCheckingType = .no
        self.appleIDTextField.smartQuotesType = .no
        self.appleIDTextField.smartDashesType = .no
        self.appleIDTextField.smartInsertDeleteType = .no
        self.appleIDTextField.keyboardType = .emailAddress
        self.appleIDTextField.textContentType = .username

        self.passwordTextField.autocapitalizationType = .none
        self.passwordTextField.autocorrectionType = .no
        self.passwordTextField.spellCheckingType = .no
        self.passwordTextField.smartQuotesType = .no
        self.passwordTextField.smartDashesType = .no
        self.passwordTextField.smartInsertDeleteType = .no
        self.passwordTextField.textContentType = .password

        #if os(tvOS)
        self.appleIDBackgroundView.backgroundColor = .clear
        self.passwordBackgroundView.backgroundColor = .clear
        self.appleIDBackgroundView.isUserInteractionEnabled = true
        self.passwordBackgroundView.isUserInteractionEnabled = true
        self.appleIDTextField.borderStyle = .roundedRect
        self.passwordTextField.borderStyle = .roundedRect
        #endif

        if UIScreen.main.isExtraCompactHeight
        {
            self.contentStackView.spacing = 20
        }
        
        self.appleIDTextField.delegate = self
        self.passwordTextField.delegate = self

        NotificationCenter.default.addObserver(self, selector: #selector(AuthenticationViewController.textFieldDidChangeText(_:)), name: UITextField.textDidChangeNotification, object: self.appleIDTextField)
        NotificationCenter.default.addObserver(self, selector: #selector(AuthenticationViewController.textFieldDidChangeText(_:)), name: UITextField.textDidChangeNotification, object: self.passwordTextField)
        
        self.update()
    }
    
    override func viewDidDisappear(_ animated: Bool)
    {
        super.viewDidDisappear(animated)
        
        self.signInButton.isIndicatingActivity = false
        self.toastView?.dismiss()
    }

    override var keyCommands: [UIKeyCommand]? {
        return [
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleTabKey(_:))),
            UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(handleShiftTabKey(_:)))
        ]
    }

    @objc private func handleTabKey(_ command: UIKeyCommand) {
        if self.appleIDTextField.isFirstResponder {
            self.passwordTextField.becomeFirstResponder()
        } else if self.passwordTextField.isFirstResponder {
            self.appleIDTextField.becomeFirstResponder()
        }
    }

    @objc private func handleShiftTabKey(_ command: UIKeyCommand) {
        if self.passwordTextField.isFirstResponder {
            self.appleIDTextField.becomeFirstResponder()
        } else if self.appleIDTextField.isFirstResponder {
            self.passwordTextField.becomeFirstResponder()
        }
    }
}

private extension AuthenticationViewController
{
    func update()
    {
        if let _ = self.validate()
        {
            self.signInButton.isEnabled = true
            self.signInButton.alpha = 1.0
        }
        else
        {
            self.signInButton.isEnabled = false
            self.signInButton.alpha = 0.6
        }
    }
    
    func validate() -> (String, String)?
    {
        guard
            let emailAddress = self.appleIDTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines), !emailAddress.isEmpty,
            let password = self.passwordTextField.text, !password.isEmpty
        else { return nil }
        
        return (emailAddress, password)
    }
}

private extension AuthenticationViewController
{
    @IBAction func authenticate()
    {
        guard let (emailAddress, password) = self.validate() else { return }
        
        self.appleIDTextField.resignFirstResponder()
        self.passwordTextField.resignFirstResponder()
        
        self.signInButton.isIndicatingActivity = true
        
        self.authenticationHandler?(emailAddress, password) { (result) in
            switch result
            {
            case .failure(DeveloperPortalError.userCancelled):
                debugLog("AuthenticationViewController: Two-factor authentication cancelled by user.")
                DispatchQueue.main.async {
                    self.signInButton.isIndicatingActivity = false
                }

            case .failure(DeveloperPortalError.accountRepairRequired):
                debugLog("AuthenticationViewController: Account repair cancelled by user.")
                DispatchQueue.main.async {
                    self.signInButton.isIndicatingActivity = false
                }

            case .failure(let error):
                DispatchQueue.main.async {
                    let details = IPAAccountSignInFailure(error)
                    let displayError = self.iPAStoreInteractive
                        ? NSError(domain: "iPAStore.SignIn", code: (error as NSError).code, userInfo: [NSLocalizedDescriptionKey: details.message])
                            .withLocalizedTitle(details.title)
                        : (error as NSError).withLocalizedTitle(NSLocalizedString("Failed to Sign In", comment: ""))
                    let toast = ToastView(error: displayError)
                    self.toastView?.dismiss()
                    toast.show(in: self)
                    toast.backgroundColor = self.iPAStoreInteractive ? .systemGray6 : .white
                    let textColor: UIColor = self.iPAStoreInteractive ? self.iPAStoreAccent : .altPrimary
                    toast.textLabel.textColor = textColor
                    toast.detailTextLabel.textColor = textColor
                    self.toastView = toast
                    self.signInButton.isIndicatingActivity = false
                }
                
            case .success((let account, let session)):
                DispatchQueue.main.async {
                    UIView.performWithoutAnimation {
                        let title = NSLocalizedString("Authenticated", comment: "")
                        let image = UIImage(systemName: "checkmark.circle.fill")
                        self.signInButton.setTitle(title, for: .normal)
                        self.signInButton.setImage(image, for: .normal)
                        self.signInButton.isIndicatingActivity = false
                        self.signInButton.layoutIfNeeded()
                    }
                }
                self.completionHandler?((account, session, password))
            }
            
            DispatchQueue.main.async {
                self.scrollView.setContentOffset(CGPoint(x: 0, y: -self.view.safeAreaInsets.top), animated: true)
            }
        }
    }
    
    @IBAction func cancel(_ sender: UIBarButtonItem)
    {
        self.dismiss(animated: true) { [weak self] in
            self?.completionHandler?(nil)
        }
    }
}

extension AuthenticationViewController: UITextFieldDelegate
{
    func textFieldShouldReturn(_ textField: UITextField) -> Bool
    {
        switch textField
        {
        case self.appleIDTextField: self.passwordTextField.becomeFirstResponder()
        case self.passwordTextField: self.authenticate()
        default: break
        }
        
        self.update()
        
        return false
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool
    {
        if string == "\t"
        {
            switch textField
            {
            case self.appleIDTextField: self.passwordTextField.becomeFirstResponder()
            case self.passwordTextField: self.appleIDTextField.becomeFirstResponder()
            default: break
            }
            return false
        }
        return true
    }
    
    func textFieldDidBeginEditing(_ textField: UITextField)
    {
        guard UIScreen.main.isExtraCompactHeight else { return }
        
        // Position all the controls within visible frame.
        var contentOffset = self.scrollView.contentOffset
        contentOffset.y = 44
        self.scrollView.setContentOffset(contentOffset, animated: true)
    }
}

extension AuthenticationViewController
{
    @objc func textFieldDidChangeText(_ notification: Notification)
    {
        self.update()
    }

    #if os(tvOS)
    @objc private func focusAppleID()
    {
        self.appleIDTextField.becomeFirstResponder()
    }
    
    @objc private func focusPassword()
    {
        self.passwordTextField.becomeFirstResponder()
    }
    #endif
}


struct IPAAccountSignInFailure {
    let title: String
    let message: String

    init(_ error: Error) {
        let nsError = error as NSError
        let reason = nsError.localizedDescription.lowercased()
        if nsError.code == 503 || reason.contains("503 service temporarily unavailable") {
            title = "Signing Service Unavailable"
            message = "Apple sign-in is temporarily unavailable. Try again in a few minutes."
        } else if nsError.code == -45063 || reason.contains("-45063") {
            title = "Apple Couldn’t Complete Sign-In"
            message = "Check your Apple Account in iPhone Settings, complete any verification Apple requests, then try again."
        } else if let portal = error as? DeveloperPortalError, case .incorrectCredentials = portal {
            title = "Check Your Apple Account"
            message = "The email address or password didn’t match. Check both and try again."
        } else if let portal = error as? DeveloperPortalError, case .incorrectVerificationCode = portal {
            title = "Verification Code Didn’t Match"
            message = "Enter the latest code from Apple and try again."
        } else {
            title = "Couldn’t Sign In"
            message = "Check your connection and try again. Complete any verification Apple requests."
        }
    }
}

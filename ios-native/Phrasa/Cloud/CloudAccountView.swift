import AuthenticationServices
import SwiftUI

struct CloudAccountView: View {
    @Bindable var coordinator: CloudCoordinator
    /// Shipping path: single runtime owns prepare → live preflight → network → apply.
    private let runtime: CloudAccountSyncRuntime?
    /// Test-only override path when a runtime is not injected.
    private let syncInputProvider: ((UUID) async throws -> CloudSyncPreparationOutcome)?
    private let applySyncResult: ((CloudSyncResult) async throws -> Void)?
    /// Test-only live preflight when using the non-runtime init path.
    private let preflightProvider: (() -> CloudSyncPreflightValidator)?

    @State private var accountMode: AccountMode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var recoveredPassword = ""
    @State private var recoveredPasswordConfirmation = ""
    @State private var recoveryValidationMessage: String?
    @State private var showingAccountDeletion = false
    @State private var accountDeletionConfirmation = ""
    @State private var accountDeletionUserID: UUID?
    /// When set, the user confirmed DELETE for an Apple-linked account and must
    /// reauthorize with SIWA to obtain a one-time authorization code.
    @State private var pendingAppleLinkedDeletionUserID: UUID?
    /// Raw nonce retained for the in-flight Sign in with Apple attempt.
    @State private var appleSignInAttempt: AppleSignInSupport.AuthorizationAttempt?
    /// Separate nonce attempt for deletion reauthorization (never reused for sign-in).
    @State private var appleDeletionReauthAttempt: AppleSignInSupport.AuthorizationAttempt?

    init(runtime: CloudAccountSyncRuntime) {
        self.coordinator = runtime.coordinator
        self.runtime = runtime
        self.syncInputProvider = nil
        self.applySyncResult = nil
        self.preflightProvider = nil
    }

    init(
        coordinator: CloudCoordinator,
        syncInputProvider: ((UUID) async throws -> CloudSyncPreparationOutcome)? = nil,
        applySyncResult: ((CloudSyncResult) async throws -> Void)? = nil,
        preflightProvider: (() -> CloudSyncPreflightValidator)? = nil
    ) {
        self.coordinator = coordinator
        self.runtime = nil
        self.syncInputProvider = syncInputProvider
        self.applySyncResult = applySyncResult
        self.preflightProvider = preflightProvider
    }

    var body: some View {
        Form {
            availabilitySection
            if coordinator.availability == .ready {
                accountSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(PhrasaDesign.canvas)
        .navigationTitle("Account & sync")
        .navigationBarTitleDisplayMode(.inline)
        .task { coordinator.start() }
        .onChange(of: coordinator.authState) { _, state in
            switch state {
            case .passwordRecovery:
                break
            case .loading, .signedOut, .signedIn:
                clearRecoveryFields()
            }

            guard case .signedIn = state else {
                clearAccountDeletionUI()
                return
            }
            if case .signedIn(let user) = state {
                if let confirmationUserID = accountDeletionUserID,
                   confirmationUserID != user.id {
                    showingAccountDeletion = false
                    accountDeletionConfirmation = ""
                    accountDeletionUserID = nil
                }
                if let pending = pendingAppleLinkedDeletionUserID,
                   pending != user.id {
                    pendingAppleLinkedDeletionUserID = nil
                    appleDeletionReauthAttempt = nil
                }
            }
        }
        .alert("Delete cloud account?", isPresented: $showingAccountDeletion) {
            TextField("Type DELETE", text: $accountDeletionConfirmation)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {
                accountDeletionConfirmation = ""
                accountDeletionUserID = nil
            }
            Button("Delete account", role: .destructive) {
                guard accountDeletionConfirmation == "DELETE",
                      let expectedUserID = accountDeletionUserID
                else { return }
                accountDeletionConfirmation = ""
                accountDeletionUserID = nil
                beginConfirmedAccountDeletion(expectedUserID: expectedUserID)
            }
            .disabled(
                accountDeletionConfirmation != "DELETE"
                    || accountDeletionUserID == nil
                    || coordinator.isAuthenticating
                    || coordinator.isSynchronizing
            )
        } message: {
            if case .signedIn(let user) = coordinator.authState,
               AccountDeletionPolicy.requiresAppleReauthorization(for: user) {
                Text(AppleSignInPresentation.deletionReauthorizationAlertMessage)
            } else {
                Text("This permanently deletes your cloud account and the cloud copies of synced scripts and folders. All content and settings already saved on this device stay unchanged. This cannot be undone.")
            }
        }
    }

    @ViewBuilder
    private var availabilitySection: some View {
        switch coordinator.availability {
        case .ready:
            EmptyView()
        case .offlineOnly:
            Section {
                Label("This build is set up for offline use only.", systemImage: "iphone")
                Text("Your scripts remain available on this device. Cloud sync can be added later without changing the offline library.")
                    .font(.footnote)
                    .foregroundStyle(PhrasaDesign.muted)
            }
        case .unavailable(let message):
            Section {
                Label("Cloud setup needs attention", systemImage: "exclamationmark.cloud")
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(PhrasaDesign.muted)
                Text("Offline reading and editing are unaffected.")
                    .font(.footnote)
                    .foregroundStyle(PhrasaDesign.muted)
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        switch coordinator.authState {
        case .loading:
            Section {
                HStack {
                    ProgressView()
                    Text("Checking your account…")
                }
            }
        case .signedOut:
            signedOutSection
        case .signedIn(let user):
            signedInSection(user)
        case .passwordRecovery(let user):
            passwordRecoverySection(user)
        }
    }

    private var signedOutSection: some View {
        Group {
            Section {
                SignInWithAppleButton(.signIn) { request in
                    do {
                        let attempt = try AppleSignInSupport.beginAttempt()
                        appleSignInAttempt = attempt
                        AppleSignInSupport.configure(request, attempt: attempt)
                    } catch {
                        appleSignInAttempt = nil
                        coordinator.reportAuthenticationFailure(error)
                    }
                } onCompletion: { result in
                    handleAppleSignInCompletion(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 44)
                .disabled(coordinator.isAuthenticating || coordinator.isSynchronizing)
                .accessibilityLabel("Sign in with Apple")
            } header: {
                Text(AppleSignInPresentation.primarySectionHeader)
            } footer: {
                Text(AppleSignInPresentation.signedOutFooter)
            }

            Section {
                Picker("Account action", selection: $accountMode) {
                    ForEach(AccountMode.allCases) { mode in Text(mode.label).tag(mode) }
                }
                .pickerStyle(.segmented)

                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(accountMode == .signIn ? .password : .newPassword)

                Button(accountMode.buttonLabel) {
                    Task {
                        if accountMode == .signIn {
                            await coordinator.signIn(email: email, password: password)
                        } else {
                            await coordinator.signUp(email: email, password: password)
                        }
                    }
                }
                .disabled(
                    email.isEmpty
                        || password.isEmpty
                        || coordinator.isAuthenticating
                        || coordinator.isSynchronizing
                )

                Button("Forgot password?") {
                    Task { await coordinator.sendPasswordReset(email: email) }
                }
                .disabled(
                    email.isEmpty
                        || coordinator.isAuthenticating
                        || coordinator.isSynchronizing
                )
            } header: {
                Text(AppleSignInPresentation.secondarySectionHeader)
            } footer: {
                Text("Secondary fallback when Sign in with Apple is unavailable. An account remains optional.")
            }

            messageSection
        }
    }

    private func signedInSection(_ user: CloudUser) -> some View {
        Group {
            Section {
                HStack {
                    Text("Signed in as")
                    Spacer()
                    Text(user.email ?? "Phrasa user")
                        .foregroundStyle(PhrasaDesign.muted)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                syncStatusView

                if let presentation = runtime?.userPresentation {
                    Label(presentation.label, systemImage: presentation.systemImage)
                        .foregroundStyle(presentation.tint)
                }

                Button {
                    Task { await synchronize() }
                } label: {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!canRequestManualSync)
            } header: {
                Text("Library sync")
            } footer: {
                if !isSyncConnected {
                    Text("Sync is ready but has not yet been connected to the local library screen.")
                } else {
                    Text("Phrasa merges script and folder changes made on only one side. If the same script changed differently here and in the cloud, it keeps the cloud version and saves this device’s edit as an unfiled “Local conflict” copy. Conflicting folder renames stop sync before either name is replaced. Reader settings stay only on this device for this release. Older or restored items whose account ownership cannot be verified stay device-only; Phrasa shows their exact count after sync and never claims them for this account automatically. Explicit adoption is deferred until a trustworthy backup confirmation path exists. After you sign in, saved scripts, folders, tags, and outlines sync automatically on launch, when the app returns to the foreground, and shortly after durable library changes. Unsaved drafts are not uploaded. You can also tap Sync now.")
                }
            }

            Section {
                Button("Sign out") {
                    Task { await coordinator.signOut() }
                }
                .disabled(coordinator.isAuthenticating || coordinator.isSynchronizing)

                Button(role: .destructive) {
                    pendingAppleLinkedDeletionUserID = nil
                    appleDeletionReauthAttempt = nil
                    accountDeletionConfirmation = ""
                    accountDeletionUserID = user.id
                    showingAccountDeletion = true
                } label: {
                    if coordinator.isDeletingAccount {
                        HStack {
                            ProgressView()
                            Text("Deleting cloud account…")
                        }
                    } else {
                        Label("Delete cloud account", systemImage: "trash")
                    }
                }
                .disabled(coordinator.isAuthenticating || coordinator.isSynchronizing)
            } header: {
                Text("Account")
            } footer: {
                Text(AccountDeletionPolicy.deletionFooter(for: user))
            }

            if pendingAppleLinkedDeletionUserID == user.id {
                Section {
                    SignInWithAppleButton(.continue) { request in
                        do {
                            let attempt = try AppleSignInSupport.beginAttempt()
                            appleDeletionReauthAttempt = attempt
                            AppleSignInSupport.configureDeletionReauthorization(
                                request,
                                attempt: attempt
                            )
                        } catch {
                            appleDeletionReauthAttempt = nil
                            coordinator.reportAuthenticationFailure(error)
                        }
                    } onCompletion: { result in
                        handleAppleDeletionReauthorization(result, expectedUserID: user.id)
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(coordinator.isAuthenticating || coordinator.isSynchronizing)
                    .accessibilityLabel(AppleSignInPresentation.deletionReauthorizationButtonLabel)

                    Button("Cancel deletion") {
                        pendingAppleLinkedDeletionUserID = nil
                        appleDeletionReauthAttempt = nil
                    }
                    .disabled(coordinator.isAuthenticating || coordinator.isSynchronizing)
                } header: {
                    Text(AppleSignInPresentation.deletionReauthorizationHeader)
                } footer: {
                    Text(AppleSignInPresentation.deletionReauthorizationFooter)
                }
            }

            messageSection
        }
    }

    private func passwordRecoverySection(_ user: CloudUser) -> some View {
        Group {
            Section {
                LabeledContent("Account", value: user.email ?? "Phrasa user")
                SecureField("New password", text: $recoveredPassword)
                    .textContentType(.newPassword)
                SecureField("Confirm new password", text: $recoveredPasswordConfirmation)
                    .textContentType(.newPassword)

                if let recoveryValidationMessage {
                    Label(recoveryValidationMessage, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(PhrasaDesign.ember)
                }

                Button {
                    submitRecoveredPassword()
                } label: {
                    if coordinator.isAuthenticating {
                        HStack {
                            ProgressView()
                            Text("Updating password…")
                        }
                    } else {
                        Text("Set new password")
                    }
                }
                .disabled(
                    recoveredPassword.isEmpty
                        || recoveredPasswordConfirmation.isEmpty
                        || coordinator.isAuthenticating
                        || coordinator.isSynchronizing
                )
            } header: {
                Text("Choose a new password")
            } footer: {
                Text("Use at least 8 characters. Both entries must match.")
            }

            Section {
                Button("Cancel and sign out") {
                    clearRecoveryFields()
                    Task { await coordinator.signOut() }
                }
                .disabled(coordinator.isAuthenticating || coordinator.isSynchronizing)
            }

            messageSection
        }
        .onChange(of: recoveredPassword) { _, _ in refreshRecoveryValidation() }
        .onChange(of: recoveredPasswordConfirmation) { _, _ in refreshRecoveryValidation() }
    }

    @ViewBuilder
    private var syncStatusView: some View {
        switch coordinator.syncStatus {
        case .idle:
            Label("Ready to sync", systemImage: "checkmark.circle")
                .foregroundStyle(PhrasaDesign.muted)
        case .syncing:
            HStack {
                ProgressView()
                Text("Syncing safely…")
            }
        case .succeeded(let summary):
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Synced · \(summary.uploadedScripts) up, \(summary.downloadedScripts) down",
                    systemImage: "checkmark.icloud"
                )
                .foregroundStyle(PhrasaDesign.success)

                if let warning = CloudSyncDisclosure.deviceOnlyWarning(for: summary) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(PhrasaDesign.ember)
                }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.icloud")
                .font(.footnote)
                .foregroundStyle(PhrasaDesign.ember)
        case .deferred(let reason):
            Label(reason.userFacingMessage, systemImage: "pencil.and.outline")
                .font(.footnote)
                .foregroundStyle(PhrasaDesign.ember)
        }
    }

    @ViewBuilder
    private var messageSection: some View {
        if let message = coordinator.accountMessage {
            Section {
                Text(message).font(.footnote)
                Button("Dismiss") { coordinator.clearAccountMessage() }
                    .font(.footnote)
            }
        }
    }

    private var isSyncConnected: Bool {
        runtime != nil || (syncInputProvider != nil && applySyncResult != nil)
    }

    private var canRequestManualSync: Bool {
        if let runtime {
            return runtime.canRequestManualSync
        }
        return coordinator.canSync && syncInputProvider != nil && applySyncResult != nil
    }

    private func synchronize() async {
        if let runtime {
            await runtime.syncNow()
            return
        }
        guard let synchronization = coordinator.beginSynchronization() else { return }
        guard let syncInputProvider,
              let applySyncResult
        else {
            coordinator.reportLocalSyncPreparationFailure(
                CloudRepositoryError.notAuthenticated,
                for: synchronization
            )
            return
        }
        let accountID = synchronization.accountID
        let input: CloudSyncInput
        do {
            switch try await syncInputProvider(accountID) {
            case .deferred(let reason):
                coordinator.reportLocalSyncDeferred(reason, for: synchronization)
                return
            case .ready(let prepared):
                input = prepared
            }
        } catch {
            coordinator.reportLocalSyncPreparationFailure(
                error,
                for: synchronization
            )
            return
        }
        let preflight = preflightProvider?() ?? CloudSyncPreflight.unsafeTestOnlyAlwaysEligible
        guard let result = await coordinator.synchronize(
            synchronization,
            local: input,
            preferences: .localOnly,
            preflight: preflight
        ) else { return }
        do {
            try await applySyncResult(result)
            coordinator.reportLocalSyncApplied(
                result.summary,
                for: synchronization
            )
        } catch {
            coordinator.reportLocalMergeFailure(
                error,
                for: synchronization
            )
        }
    }

    private func submitRecoveredPassword() {
        if let message = RecoveredPasswordValidator.message(
            password: recoveredPassword,
            confirmation: recoveredPasswordConfirmation
        ) {
            recoveryValidationMessage = message
            return
        }

        let password = recoveredPassword
        Task {
            if await coordinator.completePasswordRecovery(password: password) {
                clearRecoveryFields()
            }
        }
    }

    private func refreshRecoveryValidation() {
        guard recoveryValidationMessage != nil else { return }
        recoveryValidationMessage = RecoveredPasswordValidator.message(
            password: recoveredPassword,
            confirmation: recoveredPasswordConfirmation
        )
    }

    private func clearRecoveryFields() {
        recoveredPassword = ""
        recoveredPasswordConfirmation = ""
        recoveryValidationMessage = nil
    }

    private func handleAppleSignInCompletion(_ result: Result<ASAuthorization, Error>) {
        let attempt = appleSignInAttempt
        appleSignInAttempt = nil
        switch result {
        case .failure(let error):
            // Cancellation returns nil — no alarming account message.
            if AppleSignInSupport.userFacingFailureMessage(for: error) != nil {
                coordinator.reportAuthenticationFailure(error)
            }
        case .success(let authorization):
            guard let attempt else {
                coordinator.reportAuthenticationFailure(
                    AppleSignInSupport.CredentialError.missingCredential
                )
                return
            }
            do {
                let idToken = try AppleSignInSupport.identityToken(from: authorization)
                Task {
                    await coordinator.signInWithApple(
                        idToken: idToken,
                        nonce: attempt.rawNonce
                    )
                }
            } catch {
                coordinator.reportAuthenticationFailure(error)
            }
        }
    }

    private func beginConfirmedAccountDeletion(expectedUserID: UUID) {
        guard case .signedIn(let user) = coordinator.authState, user.id == expectedUserID else {
            coordinator.reportAuthenticationFailure(AccountDeletionError.accountChanged)
            return
        }
        if AccountDeletionPolicy.requiresAppleReauthorization(for: user) {
            pendingAppleLinkedDeletionUserID = expectedUserID
            appleDeletionReauthAttempt = nil
            return
        }
        pendingAppleLinkedDeletionUserID = nil
        Task { await coordinator.deleteAccount(expectedUserID: expectedUserID) }
    }

    private func handleAppleDeletionReauthorization(
        _ result: Result<ASAuthorization, Error>,
        expectedUserID: UUID
    ) {
        let attempt = appleDeletionReauthAttempt
        appleDeletionReauthAttempt = nil
        switch result {
        case .failure(let error):
            if AppleSignInSupport.userFacingFailureMessage(for: error) != nil {
                coordinator.reportAuthenticationFailure(error)
            }
            // Cancellation or failure: leave the reauth section so the user can retry.
        case .success(let authorization):
            guard attempt != nil else {
                coordinator.reportAuthenticationFailure(
                    AppleSignInSupport.CredentialError.missingCredential
                )
                return
            }
            do {
                let material = try AppleSignInSupport.deletionReauthorization(from: authorization)
                pendingAppleLinkedDeletionUserID = nil
                Task {
                    await coordinator.deleteAppleLinkedAccount(
                        expectedUserID: expectedUserID,
                        reauthorization: material
                    )
                }
            } catch {
                coordinator.reportAuthenticationFailure(error)
            }
        }
    }

    private func clearAccountDeletionUI() {
        showingAccountDeletion = false
        accountDeletionConfirmation = ""
        accountDeletionUserID = nil
        pendingAppleLinkedDeletionUserID = nil
        appleDeletionReauthAttempt = nil
    }
}

enum CloudSyncDisclosure {
    static func deviceOnlyWarning(for summary: CloudSyncSummary) -> String? {
        let scriptCount = summary.excludedLocalScriptCount
        let folderCount = summary.excludedLocalFolderCount
        guard scriptCount > 0 || folderCount > 0 else { return nil }

        let scripts = "\(scriptCount) \(scriptCount == 1 ? "script" : "scripts")"
        let folders = "\(folderCount) \(folderCount == 1 ? "folder" : "folders")"
        return "Needs attention: \(scripts) and \(folders) remain only on this device because they belong to another account or have unverified ownership. Explicit adoption is deferred until backup confirmation is trustworthy."
    }
}

private enum AccountMode: String, CaseIterable, Identifiable {
    case signIn
    case createAccount

    var id: Self { self }
    var label: String { self == .signIn ? "Sign in" : "Create" }
    var buttonLabel: String { self == .signIn ? "Sign in" : "Create account" }
}

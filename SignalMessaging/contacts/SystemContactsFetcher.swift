//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import Contacts
import ContactsUI
import SignalServiceKit

enum Result<T, ErrorType> {
    case success(T)
    case error(ErrorType)
}

protocol ContactStoreAdaptee {
    var authorizationStatus: ContactStoreAuthorizationStatus { get }
    var supportsContactEditing: Bool { get }
    func requestAccess(completionHandler: @escaping (Bool, Error?) -> Void)
    func fetchContacts() -> Result<[Contact], Error>
    func startObservingChanges(changeHandler: @escaping () -> Void)
}

class ContactsFrameworkContactStoreAdaptee: ContactStoreAdaptee {
    let TAG = "[ContactsFrameworkContactStoreAdaptee]"
    private let contactStore = CNContactStore()
    private var changeHandler: (() -> Void)?
    private var initializedObserver = false
    private var lastSortOrder: CNContactSortOrder?

    let supportsContactEditing = true

    private let allowedContactKeys: [CNKeyDescriptor] = [
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        CNContactThumbnailImageDataKey as CNKeyDescriptor, // TODO full image instead of thumbnail?
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactPostalAddressesKey as CNKeyDescriptor,
        CNContactViewController.descriptorForRequiredKeys()
    ]

    var authorizationStatus: ContactStoreAuthorizationStatus {
        switch CNContactStore.authorizationStatus(for: CNEntityType.contacts) {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized:
             return .authorized
        }
    }

    func startObservingChanges(changeHandler: @escaping () -> Void) {
        // should only call once
        assert(self.changeHandler == nil)
        self.changeHandler = changeHandler
        self.lastSortOrder = CNContactsUserDefaults.shared().sortOrder
        NotificationCenter.default.addObserver(self, selector: #selector(runChangeHandler), name: .CNContactStoreDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive), name: .OWSApplicationDidBecomeActive, object: nil)
    }

    @objc
    func didBecomeActive() {
        AppReadiness.runNowOrWhenAppIsReady {
            let currentSortOrder = CNContactsUserDefaults.shared().sortOrder

            guard currentSortOrder != self.lastSortOrder else {
                // sort order unchanged
                return
            }

            Logger.info("\(self.TAG) sort order changed: \(String(describing: self.lastSortOrder)) -> \(String(describing: currentSortOrder))")
            self.lastSortOrder = currentSortOrder
            self.runChangeHandler()
        }
    }

    @objc
    func runChangeHandler() {
        guard let changeHandler = self.changeHandler else {
            owsFail("\(TAG) trying to run change handler before it was registered")
            return
        }
        changeHandler()
    }

    func requestAccess(completionHandler: @escaping (Bool, Error?) -> Void) {
        self.contactStore.requestAccess(for: .contacts, completionHandler: completionHandler)
    }

    func fetchContacts() -> Result<[Contact], Error> {
        var systemContacts = [CNContact]()
        do {
            let contactFetchRequest = CNContactFetchRequest(keysToFetch: self.allowedContactKeys)
            contactFetchRequest.sortOrder = .userDefault
            try self.contactStore.enumerateContacts(with: contactFetchRequest) { (contact, _) -> Void in
                systemContacts.append(contact)
            }
        } catch let error as NSError {
            owsFail("\(self.TAG) Failed to fetch contacts with error:\(error)")
            return .error(error)
        }

        let contacts = systemContacts.map { Contact(systemContact: $0) }
        return .success(contacts)
    }
}

public enum ContactStoreAuthorizationStatus {
    case notDetermined,
         restricted,
         denied,
         authorized
}

@objc public protocol SystemContactsFetcherDelegate: class {
    func systemContactsFetcher(_ systemContactsFetcher: SystemContactsFetcher, updatedContacts contacts: [Contact], isUserRequested: Bool)
}

@objc
public class SystemContactsFetcher: NSObject {

    private let TAG = "[SystemContactsFetcher]"
    var lastContactUpdateHash: Int?
    var lastDelegateNotificationDate: Date?
    let contactStoreAdapter: ContactsFrameworkContactStoreAdaptee

    @objc
    public weak var delegate: SystemContactsFetcherDelegate?

    public var authorizationStatus: ContactStoreAuthorizationStatus {
        return contactStoreAdapter.authorizationStatus
    }

    @objc
    public var isAuthorized: Bool {
        guard self.authorizationStatus != .notDetermined else {
            owsFail("should have called `requestOnce` before checking authorization status.")
            return false
        }

        return self.authorizationStatus == .authorized
    }

    @objc
    public private(set) var systemContactsHaveBeenRequestedAtLeastOnce = false
    private var hasSetupObservation = false

    override init() {
        self.contactStoreAdapter = ContactsFrameworkContactStoreAdaptee()

        super.init()

        SwiftSingletons.register(self)
    }

    @objc
    public var supportsContactEditing: Bool {
        return self.contactStoreAdapter.supportsContactEditing
    }

    private func setupObservationIfNecessary() {
        SwiftAssertIsOnMainThread(#function)
        guard !hasSetupObservation else {
            return
        }
        hasSetupObservation = true
        self.contactStoreAdapter.startObservingChanges { [weak self] in
            DispatchQueue.main.async {
                self?.updateContacts(completion: nil, isUserRequested: false)
            }
        }
    }

    /**
     * Ensures we've requested access for system contacts. This can be used in multiple places,
     * where we might need contact access, but will ensure we don't wastefully reload contacts
     * if we have already fetched contacts.
     *
     * @param   completion  completion handler is called on main thread.
     */
    @objc
    public func requestOnce(completion completionParam: ((Error?) -> Void)?) {
        SwiftAssertIsOnMainThread(#function)

        // Ensure completion is invoked on main thread.
        let completion = { error in
            DispatchMainThreadSafe({
                completionParam?(error)
            })
        }

        guard !systemContactsHaveBeenRequestedAtLeastOnce else {
            completion(nil)
            return
        }
        setupObservationIfNecessary()

        switch authorizationStatus {
        case .notDetermined:
            if CurrentAppContext().isInBackground() {
                Logger.error("\(self.TAG) do not request contacts permission when app is in background")
                completion(nil)
                return
            }
            self.contactStoreAdapter.requestAccess { (granted, error) in
                if let error = error {
                    Logger.error("\(self.TAG) error fetching contacts: \(error)")
                    completion(error)
                    return
                }

                guard granted else {
                    // This case should have been caught be the error guard a few lines up.
                    owsFail("\(self.TAG) declined contact access.")
                    completion(nil)
                    return
                }

                DispatchQueue.main.async {
                    self.updateContacts(completion: completion)
                }
            }
        case .authorized:
            self.updateContacts(completion: completion)
        case .denied, .restricted:
            Logger.debug("\(TAG) contacts were \(self.authorizationStatus)")
            completion(nil)
        }
    }

    @objc
    public func fetchOnceIfAlreadyAuthorized() {
        SwiftAssertIsOnMainThread(#function)
        guard authorizationStatus == .authorized else {
            return
        }
        guard !systemContactsHaveBeenRequestedAtLeastOnce else {
            return
        }

        updateContacts(completion: nil, isUserRequested: false)
    }

    @objc
    public func userRequestedRefresh(completion: @escaping (Error?) -> Void) {
        SwiftAssertIsOnMainThread(#function)
        guard authorizationStatus == .authorized else {
            owsFail("should have already requested contact access")
            return
        }

        updateContacts(completion: completion, isUserRequested: true)
    }

    private func updateContacts(completion completionParam: ((Error?) -> Void)?, isUserRequested: Bool = false) {
        SwiftAssertIsOnMainThread(#function)

        var backgroundTask: OWSBackgroundTask? = OWSBackgroundTask(label: "\(#function)", completionBlock: { [weak self] status in
            SwiftAssertIsOnMainThread(#function)

            guard status == .expired else {
                return
            }

            guard let _ = self else {
                return
            }
            Logger.error("background task time ran out contacts fetch completed.")
        })

        // Ensure completion is invoked on main thread.
        let completion: (Error?) -> Void = { error in
            DispatchMainThreadSafe({
                completionParam?(error)
                backgroundTask = nil
            })
        }

        systemContactsHaveBeenRequestedAtLeastOnce = true
        setupObservationIfNecessary()

        DispatchQueue.global().async {

            Logger.info("\(self.TAG) fetching contacts")

            var fetchedContacts: [Contact]?
            switch self.contactStoreAdapter.fetchContacts() {
            case .success(let result):
                fetchedContacts = result
            case .error(let error):
                completion(error)
                return
            }

            guard let contacts = fetchedContacts else {
                owsFail("\(self.TAG) contacts was unexpectedly not set.")
                completion(nil)
            }

            Logger.info("\(self.TAG) fetched \(contacts.count) contacts.")
            let contactsHash  = HashableArray(contacts).hashValue

            DispatchQueue.main.async {
                var shouldNotifyDelegate = false

                if self.lastContactUpdateHash != contactsHash {
                    Logger.info("\(self.TAG) contact hash changed. new contactsHash: \(contactsHash)")
                    shouldNotifyDelegate = true
                } else if isUserRequested {
                    Logger.info("\(self.TAG) ignoring debounce due to user request")
                    shouldNotifyDelegate = true
                } else {

                    // If nothing has changed, only notify delegate (to perform contact intersection) every N hours
                    if let lastDelegateNotificationDate = self.lastDelegateNotificationDate {
                        let kDebounceInterval = TimeInterval(12 * 60 * 60)

                        let expiresAtDate = Date(timeInterval: kDebounceInterval, since: lastDelegateNotificationDate)
                        if  Date() > expiresAtDate {
                            Logger.info("\(self.TAG) debounce interval expired at: \(expiresAtDate)")
                            shouldNotifyDelegate = true
                        } else {
                            Logger.info("\(self.TAG) ignoring since debounce interval hasn't expired")
                        }
                    } else {
                        Logger.info("\(self.TAG) first contact fetch. contactsHash: \(contactsHash)")
                        shouldNotifyDelegate = true
                    }
                }

                guard shouldNotifyDelegate else {
                    Logger.info("\(self.TAG) no reason to notify delegate.")

                    completion(nil)

                    return
                }

                self.lastDelegateNotificationDate = Date()
                self.lastContactUpdateHash = contactsHash

                self.delegate?.systemContactsFetcher(self, updatedContacts: contacts, isUserRequested: isUserRequested)
                completion(nil)
            }
        }
    }
}

struct HashableArray<Element: Hashable>: Hashable {
    var elements: [Element]
    init(_ elements: [Element]) {
        self.elements = elements
    }

    var hashValue: Int {
        // random generated 32bit number
        let base = 224712574
        var position = 0
        return elements.reduce(base) { (result, element) -> Int in
            // Make sure change in sort order invalidates hash
            position += 1
            return result ^ element.hashValue + position
        }
    }

    static func == (lhs: HashableArray, rhs: HashableArray) -> Bool {
        return lhs.hashValue == rhs.hashValue
    }
}

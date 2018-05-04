//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import SignalServiceKit

@objc
public protocol ContactNameFieldViewDelegate: class {
    func nameFieldDidChange()
}

// MARK: -

class ContactNameFieldView: UIView {
    weak var delegate: ContactNameFieldViewDelegate?

    let name: String
    let initialValue: String?

    var valueView: UITextField!

    var hasUnsavedChanges = false

    // MARK: - Initializers

    @available(*, unavailable, message: "use other constructor instead.")
    required init?(coder aDecoder: NSCoder) {
        fatalError("Unimplemented")
    }

    required init(name: String, value: String?, delegate: ContactNameFieldViewDelegate) {
        self.name = name
        self.initialValue = value
        self.delegate = delegate

        super.init(frame: CGRect.zero)

        self.isUserInteractionEnabled = true
        self.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(wasTapped)))

        createContents()
    }

    func createContents() {
        let vMargin = CGFloat(10)
        self.layoutMargins = UIEdgeInsets(top: vMargin, left: 0, bottom: vMargin, right: 0)

        let stackView = UIStackView()
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.layoutMargins = .zero
        stackView.spacing = 10
        self.addSubview(stackView)
        stackView.autoPinTopToSuperviewMargin()
        stackView.autoPinBottomToSuperviewMargin()
        stackView.autoPinLeadingToSuperviewMargin()
        stackView.autoPinTrailingToSuperviewMargin()

        let nameLabel = UILabel()
        nameLabel.text = name
        nameLabel.font = UIFont.ows_dynamicTypeBody
        nameLabel.textColor = UIColor.ows_materialBlue
        nameLabel.lineBreakMode = .byTruncatingTail
        stackView.addArrangedSubview(nameLabel)
        nameLabel.setContentHuggingHigh()
        nameLabel.setCompressionResistanceHigh()

        valueView = UITextField()
        if let initialValue = initialValue {
            valueView.text = initialValue
        }
        valueView.font = UIFont.ows_dynamicTypeBody
        valueView.textColor = UIColor.black
        stackView.addArrangedSubview(valueView)

        valueView.addTarget(self, action: #selector(textFieldDidChange), for: .editingChanged)
    }

    func wasTapped(sender: UIGestureRecognizer) {
        Logger.info("\(self.logTag) \(#function)")

        guard sender.state == .recognized else {
            return
        }

        valueView.becomeFirstResponder()
    }

    func textFieldDidChange(sender: UITextField) {
        Logger.info("\(self.logTag) \(#function)")

        hasUnsavedChanges = true

        guard let delegate = self.delegate else {
            owsFail("\(logTag) missing delegate.")
            return
        }

        delegate.nameFieldDidChange()
    }

    public func value() -> String {
        guard let value = valueView.text else {
            return ""
        }
        return value
    }
}

// MARK: -

@objc
public protocol EditContactShareNameViewControllerDelegate: class {
    func editContactShareNameView(_ editContactShareNameView: EditContactShareNameViewController, didEditContactShare contactShare: OWSContact)
}

// MARK: -

@objc
public class EditContactShareNameViewController: OWSViewController, ContactNameFieldViewDelegate {
    weak var delegate: EditContactShareNameViewControllerDelegate?

    let contactShare: OWSContact

    var namePrefixView: ContactNameFieldView!
    var givenNameView: ContactNameFieldView!
    var middleNameView: ContactNameFieldView!
    var familyNameView: ContactNameFieldView!
    var nameSuffixView: ContactNameFieldView!

    var fieldViews = [ContactNameFieldView]()

    // MARK: Initializers

    @available(*, unavailable, message:"use other constructor instead.")
    required public init?(coder aDecoder: NSCoder) {
        fatalError("unimplemented")
    }

    @objc
    required public init(contactShare: OWSContact, delegate: EditContactShareNameViewControllerDelegate) {
        self.contactShare = contactShare
        self.delegate = delegate

        super.init(nibName: nil, bundle: nil)

        buildFields()
    }

    func buildFields() {
        namePrefixView = ContactNameFieldView(name: NSLocalizedString("CONTACT_FIELD_NAME_PREFIX", comment: "Label for the 'name prefix' field of a contact."),
                                              value: contactShare.namePrefix, delegate: self)
        givenNameView = ContactNameFieldView(name: NSLocalizedString("CONTACT_FIELD_GIVEN_NAME", comment: "Label for the 'given name' field of a contact."),
                                             value: contactShare.givenName, delegate: self)
        middleNameView = ContactNameFieldView(name: NSLocalizedString("CONTACT_FIELD_MIDDLE_NAME", comment: "Label for the 'middle name' field of a contact."),
                                              value: contactShare.middleName, delegate: self)
        familyNameView = ContactNameFieldView(name: NSLocalizedString("CONTACT_FIELD_FAMILY_NAME", comment: "Label for the 'family name' field of a contact."),
                                              value: contactShare.familyName, delegate: self)
        nameSuffixView = ContactNameFieldView(name: NSLocalizedString("CONTACT_FIELD_NAME_SUFFIX", comment: "Label for the 'name suffix' field of a contact."),
                                              value: contactShare.nameSuffix, delegate: self)
        fieldViews = [
            namePrefixView ,
            givenNameView ,
            middleNameView ,
            familyNameView ,
            nameSuffixView
        ]
    }

    override public var canBecomeFirstResponder: Bool {
        return true
    }

    // MARK: - View Lifecycle

    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        updateNavigationBar()
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }

    override public func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }

    override public func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
    }

    override public func loadView() {
        super.loadView()

        self.navigationItem.title = NSLocalizedString("CONTACT_SHARE_EDIT_NAME_VIEW_TITLE",
                                                      comment: "Title for the 'edit contact share name' view.")

        self.view.preservesSuperviewLayoutMargins = false
        self.view.backgroundColor = UIColor.white

        updateContent()

        updateNavigationBar()
    }

    func hasUnsavedChanges() -> Bool {
        for fieldView in fieldViews {
            if fieldView.hasUnsavedChanges {
                return true
            }
        }
        return false
    }

    func updateNavigationBar() {
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel,
                                                                target: self,
                                                                action: #selector(didPressCancel))

        if hasUnsavedChanges() {
            self.navigationItem.rightBarButtonItem =
                UIBarButtonItem(barButtonSystemItem: .save,
                                target: self,
                                action: #selector(didPressSave))
        } else {
            self.navigationItem.rightBarButtonItem = nil
        }
    }

    private func updateContent() {
        SwiftAssertIsOnMainThread(#function)

        guard let rootView = self.view else {
            owsFail("\(logTag) missing root view.")
            return
        }

        for subview in rootView.subviews {
            subview.removeFromSuperview()
        }

        let scrollView = UIScrollView()
        scrollView.preservesSuperviewLayoutMargins = false
        self.view.addSubview(scrollView)
        scrollView.layoutMargins = .zero
        scrollView.autoPinWidthToSuperview()
        scrollView.autoPin(toTopLayoutGuideOf: self, withInset: 0)
        scrollView.autoPinEdge(toSuperviewEdge: .bottom)

        let fieldsView = createFieldsView()

        // See notes on how to use UIScrollView with iOS Auto Layout:
        //
        // https://developer.apple.com/library/content/releasenotes/General/RN-iOSSDK-6_0/
        scrollView.addSubview(fieldsView)
        fieldsView.autoPinLeadingToSuperviewMargin()
        fieldsView.autoPinTrailingToSuperviewMargin()
        fieldsView.autoPinEdge(toSuperviewEdge: .top)
        fieldsView.autoPinEdge(toSuperviewEdge: .bottom)
    }

    private func createFieldsView() -> UIView {
        SwiftAssertIsOnMainThread(#function)

        let fieldsView = UIView.container()
        fieldsView.layoutMargins = .zero
        fieldsView.preservesSuperviewLayoutMargins = false

        var lastRow: UIView?

        let addSpacerRow = {
            guard let prevRow = lastRow else {
                owsFail("\(self.logTag) missing last row")
                return
            }
            let row = UIView()
            row.backgroundColor = UIColor(rgbHex: 0xdedee1)
            fieldsView.addSubview(row)
            row.autoSetDimension(.height, toSize: 1)
            row.autoPinLeadingToSuperviewMargin(withInset: self.hMargin)
            row.autoPinTrailingToSuperviewMargin()
            row.autoPinEdge(.top, to: .bottom, of: prevRow, withOffset: 0)
            lastRow = row
        }

        let addRow: ((UIView) -> Void) = { (row) in
            if lastRow != nil {
                addSpacerRow()
            }
            fieldsView.addSubview(row)
            row.autoPinLeadingToSuperviewMargin(withInset: self.hMargin)
            row.autoPinTrailingToSuperviewMargin(withInset: self.hMargin)
            if let lastRow = lastRow {
                row.autoPinEdge(.top, to: .bottom, of: lastRow, withOffset: 0)
            } else {
                row.autoPinEdge(toSuperviewEdge: .top, withInset: 0)
            }
            lastRow = row
        }

        for fieldView in fieldViews {
            addRow(fieldView)
        }

        lastRow?.autoPinEdge(toSuperviewEdge: .bottom, withInset: 0)

        return fieldsView
    }

    private let hMargin = CGFloat(16)

    // MARK: -

    func didPressSave() {
        Logger.info("\(logTag) \(#function)")

        let modifiedContactShare = contactShare.copy(withNamePrefix: namePrefixView.value(),
                                                     givenName: givenNameView.value(),
                                                     middleName: middleNameView.value(),
                                                     familyName: familyNameView.value(),
                                                     nameSuffix: nameSuffixView.value())

        guard let delegate = self.delegate else {
            owsFail("\(logTag) missing delegate.")
            return
        }

        delegate.editContactShareNameView(self, didEditContactShare: modifiedContactShare)

        self.navigationController?.popViewController(animated: true)
    }

    func didPressCancel() {
        Logger.info("\(logTag) \(#function)")

        self.navigationController?.popViewController(animated: true)
    }

    // MARK: - ContactNameFieldViewDelegate

    public func nameFieldDidChange() {
        updateNavigationBar()
    }
}

//
//  AssociatedObject.swift
//  powerNotch
//
//  Created by Alexander on 2025-10-05.
//

import Foundation
import ObjectiveC


/// Lightweight helper for Objective-C associated objects.
public struct AssociatedObject<Value: AnyObject> {
    private let key = UniqueKey()
    private let policy: objc_AssociationPolicy

    public init(_ policy: objc_AssociationPolicy = .OBJC_ASSOCIATION_RETAIN_NONATOMIC) {
        self.policy = policy
    }

    private final class UniqueKey {}

    public subscript<Owner: AnyObject>(_ owner: Owner) -> Value? {
        get { withExtendedLifetime(key) { objc_getAssociatedObject(owner, Unmanaged.passUnretained(key).toOpaque()) as? Value } }
        nonmutating set { withExtendedLifetime(key) { objc_setAssociatedObject(owner, Unmanaged.passUnretained(key).toOpaque(), newValue, policy) } }
    }
}

extension AssociatedObject: @unchecked Sendable where Value: Sendable {}

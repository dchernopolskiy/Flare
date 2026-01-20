//
//  UserDefault.swift
//  Flare
//

import Foundation
import Combine

/// Property wrapper for UserDefaults-backed Published properties
@propertyWrapper
struct UserDefault<Value> {
    let key: String
    let defaultValue: Value
    let storage: UserDefaults

    init(wrappedValue: Value, _ key: String, storage: UserDefaults = .standard) {
        self.key = key
        self.defaultValue = wrappedValue
        self.storage = storage
    }

    var wrappedValue: Value {
        get {
            storage.object(forKey: key) as? Value ?? defaultValue
        }
        set {
            storage.set(newValue, forKey: key)
        }
    }
}

/// Combine-compatible UserDefaults wrapper for use with @Published in ObservableObject
/// Usage: @PublishedUserDefault("keyName") var setting: Bool = false
@propertyWrapper
class PublishedUserDefault<Value> {
    private let key: String
    private let defaultValue: Value
    private let storage: UserDefaults

    private var cancellable: AnyCancellable?
    private let subject: CurrentValueSubject<Value, Never>

    init(wrappedValue: Value, _ key: String, storage: UserDefaults = .standard) {
        self.key = key
        self.defaultValue = wrappedValue
        self.storage = storage

        let initial = storage.object(forKey: key) as? Value ?? wrappedValue
        self.subject = CurrentValueSubject(initial)
    }

    var wrappedValue: Value {
        get { subject.value }
        set {
            storage.set(newValue, forKey: key)
            subject.send(newValue)
        }
    }

    var projectedValue: AnyPublisher<Value, Never> {
        subject.eraseToAnyPublisher()
    }
}

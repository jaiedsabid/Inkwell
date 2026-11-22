import SwiftUI

/// Stand-in for `@State` so the project builds with Command Line Tools only
/// (in recent SDKs `@State` is a macro whose plugin ships only with Xcode).
@propertyWrapper
struct Loc<T>: DynamicProperty {
    private var box: State<T>
    init(wrappedValue: T) { box = State<T>(wrappedValue: wrappedValue) }
    var wrappedValue: T {
        get { box.wrappedValue }
        nonmutating set { box.wrappedValue = newValue }
    }
    var projectedValue: Binding<T> { box.projectedValue }
}

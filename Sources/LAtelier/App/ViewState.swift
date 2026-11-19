import SwiftUI

/// `@State` est déclaré à la fois comme property wrapper et comme macro, et cette macro
/// n'est fournie qu'avec Xcode. L'alias utilise directement le property wrapper,
/// ce qui permet de compiler avec les seuls Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>

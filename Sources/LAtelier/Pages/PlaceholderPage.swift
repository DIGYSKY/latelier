import SwiftUI

/// Écran pas encore construit : dit ce qu'il contiendra et à quelle étape.
struct PlaceholderPage: View {
    let page: Page

    var body: some View {
        PageScaffold(page: page, subtitle: page.group?.tagline) {
            if let roadmap = Roadmap.of(page) {
                Card(title: "Arrive à l’étape \(roadmap.step)") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(roadmap.features, id: \.self) { feature in
                            Label(feature, systemImage: "circle.dashed")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

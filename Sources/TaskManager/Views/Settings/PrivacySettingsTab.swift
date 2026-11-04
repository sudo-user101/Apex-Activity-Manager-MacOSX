import SwiftUI

/// Settings › Privacy: what Apex may send, what it hides, and every place it
/// touches the network, in plain words.
struct PrivacySettingsTab: View {
    @AppStorage("assistantReadings") private var readings = true
    @AppStorage("blurPublicIP") private var blurPublicIP = true

    var body: some View {
        Form {
            Section("Assistant") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Include this Mac’s readings with questions", isOn: $readings)
                    Text("Applies to cloud AI providers you add: CPU, memory, disk, network, battery, the busiest apps’ names and recent alerts. Apex Agent and local models never send anything.").settingsCaption()
                }
            }
            Section("Network page") {
                Toggle("Hide my public IP until I click it", isOn: $blurPublicIP)
            }
            Section("What Apex sends, and when") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Self.network, id: \.0) { what, when in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(what).font(.callout.weight(.medium))
                            Text(when).settingsCaption()
                        }
                    }
                    Text("No account, no analytics, nothing else.").settingsCaption()
                }
            }
        }
        .settingsForm()
    }

    /// Every network call Apex makes, and what triggers it.
    static let network: [(String, String)] = [
        ("Public IP (ipify)", "While the Network page is open."),
        ("Internet speed test", "Only when you start one."),
        ("Network Doctor", "Only when you run it: your router, a public server and a test page."),
        ("Cloud storage pages and WebDAV", "Only for services you add, to read how much space is used."),
        ("AI providers", "Only the provider you pick, with your own key, when you ask a question."),
        ("Check on VirusTotal", "Only when you click it: the file’s fingerprint, opened in your browser."),
        ("Servers you add", "Only the servers you add, over SSH or Server Edition."),
        ("Pictures dropped from a browser", "Only when you drop one on a shelf: the picture itself, from the site it’s on."),
    ]
}

import MetadataAPI
import SwiftUI

/// TMDB is the only provider needing a secret; the key lives in the Keychain,
/// never the binary or the repo. See `docs/MOVIES_TV.md`.
struct PreferencesView: View {
    @State private var apiKey: String = TMDBKeyStore().key() ?? ""
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Text("Free from [themoviedb.org](https://www.themoviedb.org/settings/api). Powers movie and TV search.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("TMDB")
            } footer: {
                if saved {
                    Text("Saved").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 180)
        .onChange(of: apiKey) {
            let store = TMDBKeyStore()
            if apiKey.isEmpty {
                store.delete()
            } else {
                store.save(key: apiKey)
            }
            saved = true
        }
    }
}

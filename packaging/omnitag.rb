# Homebrew formula. Lives in <user>/homebrew-tap as Formula/omnitag.rb.
# Builds from source on the user's own machine, so no Developer ID signing and
# no notarisation are needed: Gatekeeper only quarantines downloaded binaries.
class Omnitag < Formula
  desc "Tag editor for local music, audiobook, movie and TV libraries"
  homepage "https://github.com/OWNER/omnitag"
  url "https://github.com/OWNER/omnitag/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE_AT_RELEASE"
  license "MIT"
  head "https://github.com/OWNER/omnitag.git", branch: "main"

  depends_on xcode: ["16.0", :build]
  depends_on macos: :sequoia

  def install
    system "make", "app", "CONFIG=release"
    prefix.install ".build/OmniTag.app"
    bin.write_exec_script "#{prefix}/OmniTag.app/Contents/MacOS/OmniTag"
  end

  def caveats
    <<~EOS
      OmniTag.app was installed to:
        #{prefix}/OmniTag.app

      To keep it in the Dock and Spotlight, symlink it:
        ln -sfn #{prefix}/OmniTag.app /Applications/OmniTag.app
    EOS
  end

  test do
    assert_path_exists prefix/"OmniTag.app/Contents/MacOS/OmniTag"
  end
end

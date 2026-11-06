cask "foldpin" do
  version "0.1.0"
  sha256 "b4e74c92774ca06b61f945d9562b16b945eb53dd10f3ae182fdb4e8d08e9ce68"

  url "https://github.com/JasonYHZ/Foldpin/releases/download/v#{version}/Foldpin-#{version}-universal.zip"
  name "Foldpin"
  desc "Native floating sticky notes with a block editor"
  homepage "https://github.com/JasonYHZ/Foldpin"

  depends_on macos: :tahoe

  app "Foldpin.app"

  preflight_steps do
    run "/bin/sh", args: ["-c", <<~SH]
      /usr/bin/sw_vers -productVersion | /usr/bin/awk -F. '
        $1 > 26 || ($1 == 26 && $2 >= 5) { supported = 1 }
        END {
          if (supported) exit 0
          print "Foldpin requires macOS 26.5 or later." > "/dev/stderr"
          exit 1
        }'
    SH
  end

  caveats <<~EOS
    This app is ad-hoc signed and not notarized by Apple.
    macOS Gatekeeper may block the first launch.
    Back up your complete note library before upgrading.
    Removing this cask does not remove your notes or library.
  EOS
end

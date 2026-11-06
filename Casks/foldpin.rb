cask "foldpin" do
  version "0.1.0-preview.1"
  sha256 "423294f6ee12d9c7ae6287aa751ca75fb4224e5a8414a49d95f11c4ecea9a566"

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
    This is a preview build, ad-hoc signed and not notarized by Apple.
    macOS Gatekeeper may block the first launch.
    Back up your complete note library before upgrading.
    Removing this cask does not remove your notes or library.
  EOS
end

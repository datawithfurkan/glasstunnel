cask "glasstunnel" do
  version "0.1.13"
  sha256 "9138bceccd8e5af33a7e0a71e0b881afee62d3274aa3f1293a63966e56ed60b1"

  url "https://github.com/datawithfurkan/glasstunnel/releases/download/v#{version}/Glasstunnel-#{version}.dmg",
    verified: "github.com/datawithfurkan/glasstunnel"
  name "Glasstunnel"
  desc "See your local AI coding agents from your phone"
  homepage "https://glasstunnel.io/"

  # The app updates itself in place (Sparkle), so `brew upgrade` leaves it alone
  # unless asked with --greedy.
  auto_updates true
  depends_on macos: :ventura

  app "Glasstunnel.app"

  zap trash: [
    "~/Library/Application Support/Glasstunnel",
    "~/Library/Preferences/io.glasstunnel.host.plist",
    "~/Library/Caches/io.glasstunnel.host",
  ]
end

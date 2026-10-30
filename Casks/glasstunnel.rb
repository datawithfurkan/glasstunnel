cask "glasstunnel" do
  version "0.1.11"
  sha256 "c9841ceff6f318669038f442348bf64e806c17dc3ae80ea3295a87239c9103e1"

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

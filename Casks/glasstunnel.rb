cask "glasstunnel" do
  version "0.1.12"
  sha256 "16291ce571d67d899cc42e5c1614d4fa847b26220d84f3a89e0d50bc4da795a0"

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

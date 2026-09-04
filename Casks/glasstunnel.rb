cask "glasstunnel" do
  version "0.1.10"
  sha256 "c5461a5e7768a5f45f693799443e193a787a3fbf89ccf231ae5a2a56ea88b04c"

  url "https://github.com/datawithfurkan/glasstunnel/releases/download/v#{version}/Glasstunnel-#{version}.dmg",
    verified: "github.com/datawithfurkan/glasstunnel"
  name "Glasstunnel"
  desc "See your local AI coding agents from your phone"
  homepage "https://glasstunnel.io/"

  depends_on macos: :ventura

  app "Glasstunnel.app"

  zap trash: [
    "~/Library/Application Support/Glasstunnel",
    "~/Library/Preferences/io.glasstunnel.host.plist",
    "~/Library/Caches/io.glasstunnel.host",
  ]
end

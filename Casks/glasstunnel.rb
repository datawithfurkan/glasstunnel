cask "glasstunnel" do
  version "0.1.8"
  sha256 "524ed129b10f4440ac2f37d60060f2baab0094e0da7fc3b68e9db41e7535ad97"

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

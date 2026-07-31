# Veyra React Native SDK — CocoaPods spec (consumed by React Native autolinking).
#
# The native SDK ships as a prebuilt XCFramework hosted on the Veyra artifact server
# (authenticated: your repository credentials must be in ~/.netrc — see the README).
# It is downloaded and checksum-verified at `pod install`; nothing else to configure.

require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

# Pinned by the release train to the SDK version this wrapper shipped with.
veyra_kmp_version  = "1.0.7" # VEYRA-KMP-VERSION-MARKER (pinned by the release train)
veyra_kmp_zip_url  = "https://repo.veyra.co/releases/files/VeyraKMP-1.0.7.xcframework.zip" # VEYRA-KMP-URL-MARKER
veyra_kmp_checksum = "b79fe71f7d1d5216668678fe5c23a9aa22fb691a1900aa71594b7233ccd5274f" # VEYRA-KMP-CHECKSUM-MARKER

Pod::Spec.new do |s|
  s.name         = "veyra-sdk-react-native"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["repository"]["url"].sub(/\.git\z/, "")
  s.license      = { :type => "Commercial", :text => "See README.md" }
  s.author       = "Veyra"
  s.platforms    = { :ios => "15.0" }
  s.source       = { :git => package["repository"]["url"], :tag => s.version.to_s }
  s.swift_version = "5.9"

  s.source_files = "ios/**/*.{swift,h,m}"

  if veyra_kmp_zip_url.empty?
    raise <<~MSG
      [veyra-sdk-react-native] This is a development build of the package — the Veyra
      framework URL has not been pinned. Install a released version from npm.
    MSG
  end

  # Download + verify + unpack the framework once per pod install. curl -n reads
  # ~/.netrc for the artifact-server credentials (same mechanism as Swift Package
  # Manager); the checksum is the SwiftPM one (SHA-256 of the zip).
  s.prepare_command = <<~CMD
    set -euo pipefail
    mkdir -p Artifacts
    if [ ! -d "Artifacts/VeyraKMP.xcframework" ]; then
      curl -n -f -L -o Artifacts/VeyraKMP.xcframework.zip "#{veyra_kmp_zip_url}"
      echo "#{veyra_kmp_checksum}  Artifacts/VeyraKMP.xcframework.zip" | shasum -a 256 -c -
      (cd Artifacts && unzip -q VeyraKMP.xcframework.zip && rm VeyraKMP.xcframework.zip)
    fi
  CMD

  s.vendored_frameworks = "Artifacts/VeyraKMP.xcframework"

  # The framework version travels with the podspec so a mismatch is impossible.
  s.info_plist = { "VeyraKMPVersion" => veyra_kmp_version }

  s.dependency "React-Core"
end

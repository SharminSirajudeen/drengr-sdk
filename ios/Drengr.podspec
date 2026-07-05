Pod::Spec.new do |s|
  s.name             = 'Drengr'
  s.version          = '0.1.0'
  s.summary          = '0-code mobile analytics SDK for iOS.'
  s.description      = 'Zero-code, in-process network + behavior capture for iOS: one call ' \
                        'records every URLSession exchange with secret/PII redaction applied ' \
                        'on-device, no track() calls and no changes to your networking code.'
  s.homepage         = 'https://drengr.dev'
  s.license          = { :type => 'Apache-2.0', :file => 'ios/LICENSE' }
  s.author           = { 'Drengr' => 'sharminsirajudeen11@gmail.com' }
  s.source           = { :git => 'https://github.com/SharminSirajudeen/drengr-sdk.git', :tag => "v#{s.version}" }
  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '11.0'
  s.swift_version    = '5.7'
  # Paths are relative to the repo root (the :git source clones the WHOLE repo,
  # not just ios/), even though this podspec file itself lives in ios/.
  s.source_files     = 'ios/Sources/Drengr/**/*.swift'
end

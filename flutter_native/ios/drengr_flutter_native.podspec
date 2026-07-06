Pod::Spec.new do |s|
  s.name             = 'drengr_flutter_native'
  s.version          = '0.1.0'
  s.summary          = 'Native-layer Drengr capture beneath the Dart engine.'
  s.description      = 'Wraps the native Drengr iOS SDK so URLSession traffic from native SDKs — invisible to any Dart hook — is captured with the same identity as the Dart SDK.'
  s.homepage         = 'https://drengr.dev'
  s.license          = { :type => 'Apache-2.0', :file => '../LICENSE' }
  s.author           = { 'Drengr' => 'sharminsirajudeen11@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.dependency 'Drengr', '~> 0.2.0'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.7'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end

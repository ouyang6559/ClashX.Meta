source 'https://cdn.cocoapods.org/'

platform :osx, '10.13'

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      if ['FlexibleDiff'].include? target.name
        target.build_configurations.each do |config|
          config.build_settings['SWIFT_VERSION'] = '5'
        end
      end
      if config.build_settings['MACOSX_DEPLOYMENT_TARGET'] == ''
        config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '10.10'
      end
      # 新版 Xcode 不再支持低于 10.13 的部署目标，统一抬升旧 Pod 的目标（版本号比较不能用浮点）。
      if Gem::Version.new(config.build_settings['MACOSX_DEPLOYMENT_TARGET'] || '0') < Gem::Version.new('10.13')
        config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '10.13'
      end
    end
  end
end

target 'ClashX' do
  inhibit_all_warnings!
  use_modular_headers!
  pod 'LetsMove'
  pod 'Alamofire', '~> 5.0'
  pod 'SwiftyJSON'
  pod 'RxSwift'
  pod 'RxCocoa'
  pod 'CocoaLumberjack/Swift'
  pod 'WebViewJavascriptBridge'
  pod 'Starscream','3.1.1'
  pod 'AppCenter/Analytics'
  pod 'Sparkle','~>1.0'
  pod "FlexibleDiff"
  pod 'GzipSwift'
end


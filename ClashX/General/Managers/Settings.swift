//
//  Settings.swift
//  ClashX
//
//  Created by yicheng on 2020/12/18.
//  Copyright © 2020 west2online. All rights reserved.
//

import Foundation
enum Settings {
    @UserDefault("mmdbDownloadUrl", defaultValue: "")
    static var mmdbDownloadUrl:String
    
    @UserDefault("filterInterface", defaultValue: true)
    static var filterInterface:Bool
    
    @UserDefault("disableNoti", defaultValue: false)
    static var disableNoti:Bool

    @UserDefault("usePacMode", defaultValue: false)
    static var usePacMode:Bool
    
    @UserDefault("configAutoUpdateInterval", defaultValue: 48*60*60)
    static var configAutoUpdateInterval:TimeInterval

    // MARK: VPM 登录模式（默认关闭 = 免登录，现有逻辑不变）
    @UserDefault("vpmLoginModeEnabled", defaultValue: false)
    static var vpmLoginModeEnabled:Bool

    @UserDefault("vpmAPIBaseURL", defaultValue: "http://127.0.0.1:7790")
    static var vpmAPIBaseURL:String

    @UserDefault("vpmDisplayEmail", defaultValue: "")
    static var vpmDisplayEmail:String
}

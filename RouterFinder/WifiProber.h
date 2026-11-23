#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 一个附近 WiFi 网络的观测数据
@interface WifiNetworkInfo : NSObject
@property (nonatomic, copy) NSString *ssid;
@property (nonatomic, copy) NSString *bssid;
@property (nonatomic, assign) NSInteger rssi;          // dBm
@property (nonatomic, assign) NSInteger channel;       // 信道号
@property (nonatomic, assign) NSInteger frequencyMHz;  // 频点
@property (nonatomic, copy) NSString *channelWidth;    // 频宽，如 "80 MHz"
@property (nonatomic, copy) NSString *band;            // 2.4 / 5 / 6 GHz
@property (nonatomic, copy) NSString *security;        // WPA2/WPA3/开放
@end

@interface WifiProber : NSObject

/// 扫描附近 WiFi。iOS 14+ 使用 MobileWiFi 私有框架，旧系统回退到 Apple80211。
+ (NSArray<WifiNetworkInfo *> *)scanNearby;

/// 最近一次扫描的诊断信息（失败原因或统计）
+ (NSString *)diagnostic;

@end

NS_ASSUME_NONNULL_END

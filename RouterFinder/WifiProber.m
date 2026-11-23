#import "WifiProber.h"
#import <dlfcn.h>
#import <CoreFoundation/CoreFoundation.h>

@implementation WifiNetworkInfo
@end

static NSString *gDiagnostic = @"";

#pragma mark - 通用转换工具

static NSString *RFTString(id value) {
    if ([value isKindOfClass:[NSString class]]) return (NSString *)value;
    if ([value isKindOfClass:[NSData class]]) {
        return [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding];
    }
    if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
    return nil;
}

static NSInteger RFTInt(id value) {
    if ([value respondsToSelector:@selector(integerValue)]) return [value integerValue];
    return 0;
}

/// RSSI 在 MobileWiFi 里可能直接是 NSNumber，也可能是 {"RSSI_CTL_AGR": number} 字典
static NSInteger RFTRSSI(id value) {
    if ([value isKindOfClass:[NSDictionary class]]) {
        id v = [value objectForKey:@"RSSI_CTL_AGR"] ?: [value objectForKey:@"RSSI"];
        return RFTInt(v);
    }
    return RFTInt(value);
}

/// 兼容三种返回形态：MHz 数值(20/40/80/160)、枚举值(1..5)、带 MHz 的字符串
static NSString *RFTWidth(id value) {
    if (!value) return nil;
    NSInteger n = RFTInt(value);
    if (n >= 20 && n <= 320) return [NSString stringWithFormat:@"%ld MHz", (long)n];
    NSString *s = RFTString(value);
    if (s && [s rangeOfString:@"MHz"].location != NSNotFound) return s;
    switch (n) {
        case 1:  return @"20 MHz";
        case 2:  return @"40 MHz";
        case 3:  return @"80 MHz";
        case 4:  return @"160 MHz";
        case 5:  return @"80+80 MHz";
        default: return nil;
    }
}

static NSInteger RFTFrequency(NSInteger channel) {
    if (channel <= 0) return 0;
    if (channel <= 13) return 2412 + (channel - 1) * 5;
    if (channel == 14) return 2484;
    if (channel < 197) return 5000 + channel * 5;
    return 5950 + channel * 5;   // 6 GHz 近似换算
}

static NSString *RFTBand(NSInteger freq) {
    if (freq >= 5900) return @"6 GHz";
    if (freq >= 4900) return @"5 GHz";
    if (freq > 0) return @"2.4 GHz";
    return @"未知";
}

static NSString *RFTSecurity(NSString *capabilities) {
    if (!capabilities) return @"未知";
    NSString *c = [capabilities uppercaseString];
    if ([c rangeOfString:@"WPA3"].location != NSNotFound) return @"WPA3";
    if ([c rangeOfString:@"WPA2"].location != NSNotFound) return @"WPA2";
    if ([c rangeOfString:@"WPA"].location != NSNotFound) return @"WPA";
    if ([c rangeOfString:@"WEP"].location != NSNotFound) return @"WEP";
    return @"开放";
}

/// 不同 iOS 版本、不同私有框架返回的频宽键名不一致，逐个尝试
static NSString *RFTWidthFromNetwork(NSDictionary *network) {
    NSArray *keys = @[@"CHANNEL_WIDTH", @"CHANNEL_WIDTH_MHZ", @"WIFI_CHANNEL_WIDTH",
                      @"CHANNEL_FLAG", @"CHANNEL_FLAGS", @"CHANNEL_BANDWIDTH"];
    for (NSString *key in keys) {
        NSString *w = RFTWidth([network objectForKey:key]);
        if (w) return w;
    }
    return @"未知";
}

/// 把任意一种私有框架返回的扫描结果字典统一转成模型
static WifiNetworkInfo *RFTNetworkFromDictionary(NSDictionary *net) {
    id ssidValue = [net objectForKey:@"SSID_STR"] ?: [net objectForKey:@"SSID"];
    NSString *ssid = RFTString(ssidValue);
    if (ssid.length == 0) ssid = @"(隐藏网络)";

    WifiNetworkInfo *item = [[WifiNetworkInfo alloc] init];
    item.ssid = ssid;
    item.bssid = RFTString([net objectForKey:@"BSSID"]) ?: @"";
    item.rssi = RFTRSSI([net objectForKey:@"RSSI"]);
    item.channel = RFTInt([net objectForKey:@"CHANNEL"]);
    if (item.channel == 0) item.channel = RFTInt([net objectForKey:@"CHANNEL_NUMBER"]);
    item.frequencyMHz = RFTFrequency(item.channel);
    item.band = RFTBand(item.frequencyMHz);
    item.channelWidth = RFTWidthFromNetwork(net);
    item.security = RFTSecurity(RFTString([net objectForKey:@"CAPABILITIES"]));
    return item;
}

#pragma mark - MobileWiFi（iOS 14+ 主路径）

typedef void *RFTWiFiManagerRef;
typedef void *RFTWiFiDeviceRef;
typedef void *RFTWiFiNetworkRef;
// 注意：iOS 真实签名是 (device, results, int error, const void *token)，不是 CFErrorRef
typedef void (*RFTWiFiScanCallback)(RFTWiFiDeviceRef, CFArrayRef, int, const void *);

static BOOL gMobileScanDone = NO;
static NSArray<WifiNetworkInfo *> *gMobileScanResults = nil;
static CFRunLoopRef gMobileScanRunLoop = NULL;
static NSString *gMobileScanCallbackError = nil;
static NSInteger gMobileScanRawCount = -1;

// iOS 14+ 扫描结果里是 WiFiNetworkRef 不透明对象，必须用这些 C 函数取属性
static CFPropertyListRef (*gNWGetProperty)(RFTWiFiNetworkRef, CFStringRef) = NULL;
static int (*gNWGetIntProperty)(RFTWiFiNetworkRef, CFStringRef) = NULL;
static float (*gNWGetFloatProperty)(RFTWiFiNetworkRef, CFStringRef) = NULL;
static CFStringRef (*gNWGetSSID)(RFTWiFiNetworkRef) = NULL;
static Boolean (*gNWIsWEP)(RFTWiFiNetworkRef) = NULL;
static Boolean (*gNWIsWPA)(RFTWiFiNetworkRef) = NULL;
static Boolean (*gNWIsEAP)(RFTWiFiNetworkRef) = NULL;
static Boolean (*gNWIsHidden)(RFTWiFiNetworkRef) = NULL;

/// 从 WiFiNetworkRef 不透明对象提取网络信息（iOS 14+ 扫描结果类型）
static WifiNetworkInfo *RFTNetworkFromWiFiNetworkRef(RFTWiFiNetworkRef network) {
    if (!network) return nil;
    WifiNetworkInfo *item = [[WifiNetworkInfo alloc] init];

    NSString *ssid = nil;
    if (gNWGetSSID) {
        CFStringRef ref = gNWGetSSID(network);
        if (ref) ssid = (__bridge NSString *)ref;
    }
    BOOL hidden = (gNWIsHidden && gNWIsHidden(network));
    item.ssid = (ssid.length > 0 && !hidden) ? ssid : @"(隐藏网络)";

    NSString *bssid = nil;
    if (gNWGetProperty) {
        CFPropertyListRef ref = gNWGetProperty(network, CFSTR("BSSID"));
        if (ref && CFGetTypeID(ref) == CFStringGetTypeID()) bssid = (__bridge NSString *)ref;
    }
    item.bssid = bssid ?: @"";

    NSInteger rssi = 0;
    if (gNWGetFloatProperty) {
        rssi = (NSInteger)roundf(gNWGetFloatProperty(network, CFSTR("RSSI")));
    } else if (gNWGetProperty) {
        CFPropertyListRef ref = gNWGetProperty(network, CFSTR("RSSI"));
        float f = 0;
        if (ref && CFGetTypeID(ref) == CFNumberGetTypeID() &&
            CFNumberGetValue((CFNumberRef)ref, kCFNumberFloatType, &f)) {
            rssi = (NSInteger)roundf(f);
        }
    }
    item.rssi = rssi;

    NSInteger channel = 0;
    if (gNWGetIntProperty) {
        channel = gNWGetIntProperty(network, CFSTR("CHANNEL"));
    } else if (gNWGetProperty) {
        CFPropertyListRef ref = gNWGetProperty(network, CFSTR("CHANNEL"));
        int c = 0;
        if (ref && CFGetTypeID(ref) == CFNumberGetTypeID() &&
            CFNumberGetValue((CFNumberRef)ref, kCFNumberIntType, &c)) channel = c;
    }
    item.channel = channel;
    item.frequencyMHz = RFTFrequency(channel);
    item.band = RFTBand(item.frequencyMHz);

    NSString *width = nil;
    if (gNWGetProperty) {
        NSArray *keys = @[@"CHANNEL_WIDTH", @"CHANNEL_WIDTH_MHZ", @"CHANNEL_FLAGS",
                          @"CHANNEL_BANDWIDTH", @"WIFI_CHANNEL_WIDTH"];
        for (NSString *key in keys) {
            CFPropertyListRef ref = gNWGetProperty(network, (__bridge CFStringRef)key);
            if (!ref) continue;
            if (CFGetTypeID(ref) == CFNumberGetTypeID()) {
                width = RFTWidth((__bridge NSNumber *)ref);
            } else if (CFGetTypeID(ref) == CFStringGetTypeID()) {
                width = RFTWidth((__bridge NSString *)ref);
            }
            if (width) break;
        }
    }
    item.channelWidth = width ?: @"未知";

    NSMutableArray *sec = [NSMutableArray array];
    if (gNWIsWPA && gNWIsWPA(network)) [sec addObject:@"WPA"];
    if (gNWIsWEP && gNWIsWEP(network)) [sec addObject:@"WEP"];
    if (gNWIsEAP && gNWIsEAP(network)) [sec addObject:@"EAP"];
    item.security = sec.count > 0 ? [sec componentsJoinedByString:@"/"] : @"开放";
    return item;
}

static void RFTMobileScanCallback(RFTWiFiDeviceRef device, CFArrayRef results, int error, const void *token) {
    if (error != 0) {
        gMobileScanCallbackError = [NSString stringWithFormat:@"扫描错误码 %d", error];
    }
    if (results) {
        CFIndex count = CFArrayGetCount(results);
        gMobileScanRawCount = count;
        NSMutableArray *arr = [NSMutableArray array];
        for (CFIndex i = 0; i < count; i++) {
            void *raw = (void *)CFArrayGetValueAtIndex(results, i);
            if (!raw) continue;
            WifiNetworkInfo *info = RFTNetworkFromWiFiNetworkRef(raw);
            if (info) [arr addObject:info];
        }
        gMobileScanResults = [arr copy];
    } else {
        gMobileScanRawCount = 0;
    }
    gMobileScanDone = YES;
    if (gMobileScanRunLoop) CFRunLoopStop(gMobileScanRunLoop);
}

@implementation WifiProber

/// iOS 14 起 Apple80211 已由 MobileWiFi 取代；使用异步扫描并在当前线程 RunLoop 上等待结果。
+ (NSArray<WifiNetworkInfo *> *)scanViaMobileWiFiError:(NSString **)errorMessage {
    *errorMessage = nil;
    void *handle = dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi", RTLD_NOW);
    if (!handle) {
        const char *e = dlerror();
        *errorMessage = [NSString stringWithFormat:@"无法加载 MobileWiFi（%s）", e ?: "未知错误"];
        return nil;
    }

    RFTWiFiManagerRef (*createFn)(CFAllocatorRef, int) =
        (RFTWiFiManagerRef (*)(CFAllocatorRef, int))dlsym(handle, "WiFiManagerClientCreate");
    CFArrayRef (*copyDevicesFn)(RFTWiFiManagerRef) =
        (CFArrayRef (*)(RFTWiFiManagerRef))dlsym(handle, "WiFiManagerClientCopyDevices");
    void (*scheduleFn)(RFTWiFiManagerRef, CFRunLoopRef, CFStringRef) =
        (void (*)(RFTWiFiManagerRef, CFRunLoopRef, CFStringRef))dlsym(handle, "WiFiManagerClientScheduleWithRunLoop");
    void (*unscheduleFn)(RFTWiFiManagerRef) =
        (void (*)(RFTWiFiManagerRef))dlsym(handle, "WiFiManagerClientUnscheduleFromRunLoop");
    void (*scanFn)(RFTWiFiDeviceRef, CFDictionaryRef, RFTWiFiScanCallback, uint32_t) =
        (void (*)(RFTWiFiDeviceRef, CFDictionaryRef, RFTWiFiScanCallback, uint32_t))dlsym(handle, "WiFiDeviceClientScanAsync");

    // WiFiNetworkRef 属性函数：扫描结果解析依赖它们
    gNWGetProperty      = (CFPropertyListRef (*)(RFTWiFiNetworkRef, CFStringRef))dlsym(handle, "WiFiNetworkGetProperty");
    gNWGetIntProperty   = (int (*)(RFTWiFiNetworkRef, CFStringRef))dlsym(handle, "WiFiNetworkGetIntProperty");
    gNWGetFloatProperty = (float (*)(RFTWiFiNetworkRef, CFStringRef))dlsym(handle, "WiFiNetworkGetFloatProperty");
    gNWGetSSID          = (CFStringRef (*)(RFTWiFiNetworkRef))dlsym(handle, "WiFiNetworkGetSSID");
    gNWIsWEP            = (Boolean (*)(RFTWiFiNetworkRef))dlsym(handle, "WiFiNetworkIsWEP");
    gNWIsWPA            = (Boolean (*)(RFTWiFiNetworkRef))dlsym(handle, "WiFiNetworkIsWPA");
    gNWIsEAP            = (Boolean (*)(RFTWiFiNetworkRef))dlsym(handle, "WiFiNetworkIsEAP");
    gNWIsHidden         = (Boolean (*)(RFTWiFiNetworkRef))dlsym(handle, "WiFiNetworkIsHidden");

    if (!createFn || !copyDevicesFn || !scanFn || !gNWGetProperty || !gNWGetSSID) {
        *errorMessage = @"MobileWiFi 符号缺失，当前 iOS 版本不兼容";
        dlclose(handle);
        return nil;
    }

    RFTWiFiManagerRef manager = createFn(kCFAllocatorDefault, 0);
    if (!manager) {
        *errorMessage = @"WiFiManagerClientCreate 失败（缺少 com.apple.wifi.manager-access 权限？）";
        dlclose(handle);
        return nil;
    }

    CFArrayRef devices = copyDevicesFn(manager);
    if (!devices || CFArrayGetCount(devices) == 0) {
        *errorMessage = @"获取 WiFi 设备失败（WiFi 未开启或权限不足）";
        if (devices) CFRelease(devices);
        CFRelease(manager);
        dlclose(handle);
        return nil;
    }

    RFTWiFiDeviceRef device = (RFTWiFiDeviceRef)CFArrayGetValueAtIndex(devices, 0);

    gMobileScanDone = NO;
    gMobileScanResults = nil;
    gMobileScanCallbackError = nil;
    gMobileScanRawCount = -1;
    gMobileScanRunLoop = CFRunLoopGetCurrent();

    if (scheduleFn) scheduleFn(manager, gMobileScanRunLoop, kCFRunLoopDefaultMode);

    CFDictionaryRef options = CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0,
                                                 &kCFTypeDictionaryKeyCallBacks,
                                                 &kCFTypeDictionaryValueCallBacks);
    scanFn(device, options, RFTMobileScanCallback, 0);
    CFRelease(options);

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8.0];
    while (!gMobileScanDone && [deadline timeIntervalSinceNow] > 0) {
        @autoreleasepool {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
        }
    }

    if (unscheduleFn) unscheduleFn(manager);
    CFRelease(devices);
    CFRelease(manager);
    dlclose(handle);
    gMobileScanRunLoop = NULL;

    if (!gMobileScanDone) {
        *errorMessage = @"MobileWiFi 扫描超时（wifid 未响应）";
        return nil;
    }
    if (gMobileScanCallbackError) {
        *errorMessage = [NSString stringWithFormat:@"扫描回调错误：%@", gMobileScanCallbackError];
    }
    return gMobileScanResults;
}

#pragma mark - Apple80211（旧版兜底）

+ (NSArray<WifiNetworkInfo *> *)scanViaApple80211Error:(NSString **)errorMessage {
    NSMutableArray<WifiNetworkInfo *> *items = [NSMutableArray array];
    void *handle = dlopen("/System/Library/PrivateFrameworks/Apple80211.framework/Apple80211", RTLD_NOW);
    if (!handle) {
        *errorMessage = @"无法加载 Apple80211 私有框架";
        return items;
    }

    int (*openFn)(void **) = (int (*)(void **))dlsym(handle, "Apple80211Open");
    int (*bindFn)(void *, CFStringRef) = (int (*)(void *, CFStringRef))dlsym(handle, "Apple80211BindToInterface");
    int (*scanFn)(void *, void **, void *) = (int (*)(void *, void **, void *))dlsym(handle, "Apple80211Scan");
    int (*closeFn)(void *) = (int (*)(void *))dlsym(handle, "Apple80211Close");
    if (!openFn || !scanFn) {
        *errorMessage = @"Apple80211 符号缺失";
        dlclose(handle);
        return items;
    }

    void *wifi = NULL;
    int opened = openFn(&wifi);
    if (opened != 0 || !wifi) {
        *errorMessage = [NSString stringWithFormat:@"Apple80211Open 失败 (code %d)", opened];
        dlclose(handle);
        return items;
    }
    if (bindFn) bindFn(wifi, CFSTR("en0"));

    void *rawResults = NULL;
    int status = scanFn(wifi, &rawResults, NULL);
    if (closeFn) closeFn(wifi);

    if (status != 0 || !rawResults) {
        *errorMessage = [NSString stringWithFormat:@"Apple80211Scan 失败 (code %d)", status];
        dlclose(handle);
        return items;
    }

    NSArray *networks = (__bridge NSArray *)rawResults;
    for (id obj in networks) {
        if ([obj isKindOfClass:[NSDictionary class]]) {
            [items addObject:RFTNetworkFromDictionary((NSDictionary *)obj)];
        }
    }
    dlclose(handle);
    return items;
}

#pragma mark - CoreWLAN 补充频宽

+ (void)fillWidthsFromCoreWLAN:(NSMutableArray<WifiNetworkInfo *> *)items {
    if (items.count == 0) return;
    void *cw = dlopen("/System/Library/PrivateFrameworks/CoreWLAN.framework/CoreWLAN", RTLD_NOW);
    if (!cw) return;
    Class clientClass = NSClassFromString(@"CWWiFiClient");
    if (!clientClass || ![clientClass respondsToSelector:@selector(sharedWiFiClient)]) {
        dlclose(cw);
        return;
    }
    id client = [clientClass performSelector:@selector(sharedWiFiClient)];
    NSArray *interfaces = nil;
    if (client && [client respondsToSelector:@selector(interfaces)]) {
        interfaces = [client performSelector:@selector(interfaces)];
    }
    NSMutableDictionary<NSString *, NSString *> *widths = [NSMutableDictionary dictionary];
    for (id iface in interfaces) {
        @try {
            NSString *bssid = [iface valueForKey:@"bssid"];
            id channel = [iface valueForKey:@"channel"];
            NSString *w = RFTWidth([channel valueForKey:@"channelWidth"]);
            if (bssid && w) [widths setObject:w forKey:[bssid uppercaseString]];
        } @catch (NSException *exception) {
            // 私有 API 在不同版本签名可能变化，忽略单个接口失败
        }
    }
    for (WifiNetworkInfo *item in items) {
        if (item.bssid.length > 0 &&
            (item.channelWidth.length == 0 || [item.channelWidth isEqualToString:@"未知"])) {
            NSString *w = [widths objectForKey:[item.bssid uppercaseString]];
            if (w) item.channelWidth = w;
        }
    }
    dlclose(cw);
}

#pragma mark - 对外接口

+ (NSString *)diagnostic {
    return gDiagnostic;
}

+ (NSString *)widthFromNetwork:(NSDictionary *)network {
    return RFTWidthFromNetwork(network);
}

+ (NSArray<WifiNetworkInfo *> *)scanNearby {
    NSMutableArray<WifiNetworkInfo *> *items = [NSMutableArray array];
    NSMutableArray<NSString *> *notes = [NSMutableArray array];

    NSString *mobileError = nil;
    NSArray *mobileResults = [self scanViaMobileWiFiError:&mobileError];
    if (mobileResults.count > 0) {
        [items addObjectsFromArray:mobileResults];
        [notes addObject:[NSString stringWithFormat:@"MobileWiFi 扫描到 %lu 个网络", (unsigned long)mobileResults.count]];
    } else {
        if (gMobileScanRawCount > 0 && mobileError == nil) {
            [notes addObject:[NSString stringWithFormat:@"MobileWiFi 收到 %ld 个结果但解析失败", (long)gMobileScanRawCount]];
        } else {
            [notes addObject:[NSString stringWithFormat:@"MobileWiFi：%@", mobileError ?: @"无结果"]];
        }

        NSString *legacyError = nil;
        NSArray *legacyResults = [self scanViaApple80211Error:&legacyError];
        if (legacyResults.count > 0) {
            [items addObjectsFromArray:legacyResults];
            [notes addObject:[NSString stringWithFormat:@"Apple80211 扫描到 %lu 个网络", (unsigned long)legacyResults.count]];
        } else {
            [notes addObject:[NSString stringWithFormat:@"Apple80211：%@", legacyError ?: @"无结果"]];
        }
    }

    [self fillWidthsFromCoreWLAN:items];

    NSInteger wide = 0;
    for (WifiNetworkInfo *item in items) {
        if (item.channelWidth.length > 0 && ![item.channelWidth isEqualToString:@"未知"]) wide++;
    }
    gDiagnostic = [NSString stringWithFormat:@"%@；%ld 个网络获取到频宽。%@",
                   [notes componentsJoinedByString:@"；"],
                   (long)wide,
                   items.count == 0 ? @"若持续失败，请确认已安装 AppSync Unified 并彻底关闭后台后重开 App。" : @""];
    return items;
}

@end

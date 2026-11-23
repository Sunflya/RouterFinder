#import "WifiProber.h"
#import <dlfcn.h>
#import <CoreFoundation/CoreFoundation.h>

@implementation WifiNetworkInfo
@end

static NSString *gDiagnostic = @"";

static NSString *RFTString(id value) {
    if ([value isKindOfClass:[NSString class]]) return (NSString *)value;
    if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
    return nil;
}

static NSInteger RFTInt(id value) {
    if ([value respondsToSelector:@selector(integerValue)]) return [value integerValue];
    return 0;
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

@implementation WifiProber

+ (NSString *)diagnostic {
    return gDiagnostic;
}

/// Apple80211 的 scan 结果里，不同 iOS 版本使用的频宽键名不同，逐个尝试。
+ (NSString *)widthFromNetwork:(NSDictionary *)network {
    NSArray *keys = @[@"CHANNEL_WIDTH", @"CHANNEL_WIDTH_MHZ", @"WIFI_CHANNEL_WIDTH",
                      @"CHANNEL_FLAG", @"CHANNEL_FLAGS", @"CHANNEL_BANDWIDTH"];
    for (NSString *key in keys) {
        NSString *w = RFTWidth([network objectForKey:key]);
        if (w) return w;
    }
    return @"未知";
}

/// CoreWLAN 在 iOS 上是私有框架，尝试用它补齐当前连接网络的频宽。
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
        if ([item.bssid length] > 0 &&
            ([item.channelWidth length] == 0 || [item.channelWidth isEqualToString:@"未知"])) {
            NSString *w = [widths objectForKey:[item.bssid uppercaseString]];
            if (w) item.channelWidth = w;
        }
    }
    dlclose(cw);
}

+ (NSArray<WifiNetworkInfo *> *)scanNearby {
    NSMutableArray<WifiNetworkInfo *> *items = [NSMutableArray array];

    void *handle = dlopen("/System/Library/PrivateFrameworks/Apple80211.framework/Apple80211", RTLD_NOW);
    if (!handle) {
        gDiagnostic = @"无法加载 Apple80211 私有框架，请确认设备已越狱";
        return items;
    }

    int (*openFn)(void **) = (int (*)(void **))dlsym(handle, "Apple80211Open");
    int (*bindFn)(void *, CFStringRef) = (int (*)(void *, CFStringRef))dlsym(handle, "Apple80211BindToInterface");
    int (*scanFn)(void *, void **, void *) = (int (*)(void *, void **, void *))dlsym(handle, "Apple80211Scan");
    int (*closeFn)(void *) = (int (*)(void *))dlsym(handle, "Apple80211Close");
    if (!openFn || !scanFn) {
        gDiagnostic = @"Apple80211 符号缺失，当前 iOS 版本可能不兼容";
        dlclose(handle);
        return items;
    }

    void *wifi = NULL;
    int opened = openFn(&wifi);
    if (opened != 0 || !wifi) {
        gDiagnostic = [NSString stringWithFormat:@"Apple80211Open 失败 (code %d)", opened];
        dlclose(handle);
        return items;
    }
    if (bindFn) bindFn(wifi, CFSTR("en0"));

    void *rawResults = NULL;
    int status = scanFn(wifi, &rawResults, NULL);
    if (closeFn) closeFn(wifi);

    if (status != 0 || !rawResults) {
        gDiagnostic = [NSString stringWithFormat:@"WiFi 扫描失败 (code %d)，请确认 Wi-Fi 已开启", status];
        dlclose(handle);
        return items;
    }

    NSArray *networks = (__bridge NSArray *)rawResults;
    for (id obj in networks) {
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *net = (NSDictionary *)obj;

        WifiNetworkInfo *item = [[WifiNetworkInfo alloc] init];
        NSString *ssid = RFTString([net objectForKey:@"SSID"]);
        if (!ssid) ssid = RFTString([net objectForKey:@"SSID_STR"]);
        item.ssid = [ssid length] > 0 ? ssid : @"(隐藏网络)";
        item.bssid = RFTString([net objectForKey:@"BSSID"]) ?: @"";
        item.rssi = RFTInt([net objectForKey:@"RSSI"]);
        item.channel = RFTInt([net objectForKey:@"CHANNEL"]);
        item.frequencyMHz = RFTFrequency(item.channel);
        item.band = RFTBand(item.frequencyMHz);
        item.channelWidth = [self widthFromNetwork:net];
        item.security = RFTSecurity(RFTString([net objectForKey:@"CAPABILITIES"]));
        [items addObject:item];
    }

    dlclose(handle);
    [self fillWidthsFromCoreWLAN:items];

    NSInteger wide = 0;
    for (WifiNetworkInfo *item in items) {
        if (![item.channelWidth isEqualToString:@"未知"]) wide++;
    }
    gDiagnostic = [NSString stringWithFormat:@"发现 %ld 个网络，其中 %ld 个获取到频宽（频宽取决于路由器与系统上报能力）",
                   (long)items.count, (long)wide];
    return items;
}

@end

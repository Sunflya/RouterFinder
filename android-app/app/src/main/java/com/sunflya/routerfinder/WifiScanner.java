package com.sunflya.routerfinder;

import android.content.Context;
import android.net.wifi.ScanResult;
import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;

import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;

/**
 * 读取附近 WiFi 的信号强度(RSSI)、频段、信道与频宽。
 * getChannelWidth() 在部分系统上版本不同，用反射调用以兼容更多机型。
 */
public final class WifiScanner {
    private WifiScanner() {}

    public static class Network {
        public String ssid;
        public String bssid;
        public int rssi;              // dBm
        public int frequencyMHz;
        public int channel;
        public String band;
        public String width;
        public String security;

        public int percent() {
            if (rssi >= -40) return 100;
            if (rssi <= -95) return 0;
            return Math.max(0, Math.min(100, (rssi + 95) * 100 / 55));
        }
    }

    public static String diagnostic = "";

    public static List<Network> scan(Context context) {
        List<Network> out = new ArrayList<>();
        try {
            WifiManager wm = (WifiManager) context.getApplicationContext()
                    .getSystemService(Context.WIFI_SERVICE);
            if (wm == null) {
                diagnostic = "无法获取系统的 Wi-Fi 服务";
                return out;
            }
            if (!wm.isWifiEnabled()) {
                diagnostic = "Wi-Fi 未开启，请先打开 Wi-Fi";
                return out;
            }
            boolean started = wm.startScan();
            List<ScanResult> results = wm.getScanResults();
            if (results == null || results.isEmpty()) {
                diagnostic = "未获取到扫描结果（系统可能限制了扫描频率，请稍后重试并确认已授予位置权限）。startScan=" + started;
                return out;
            }

            String connectedBssid = "";
            WifiInfo connected = wm.getConnectionInfo();
            if (connected != null && connected.getBssid() != null) {
                connectedBssid = connected.getBssid();
            }

            for (ScanResult r : results) {
                Network n = new Network();
                n.ssid = (r.SSID == null || r.SSID.isEmpty()) ? "(隐藏网络)" : r.SSID;
                n.bssid = r.BSSID == null ? "" : r.BSSID;
                n.rssi = r.level;
                n.frequencyMHz = r.frequency;
                n.channel = frequencyToChannel(r.frequency);
                n.band = bandOf(r.frequency);
                n.width = widthOf(r);
                n.security = securityOf(r.capabilities);
                if (n.bssid.equals(connectedBssid) && "未知".equals(n.width)) {
                    String cw = connectedWidth(connected);
                    if (cw != null) n.width = cw + "（当前连接）";
                }
                out.add(n);
            }
            Collections.sort(out, new Comparator<Network>() {
                @Override
                public int compare(Network a, Network b) {
                    return Integer.compare(b.rssi, a.rssi);
                }
            });
            diagnostic = "共发现 " + out.size() + " 个网络 · 按信号强度排序（频宽取决于系统与路由器上报）";
        } catch (Exception e) {
            diagnostic = "扫描失败: " + e.getMessage();
        }
        return out;
    }

    private static String widthOf(ScanResult result) {
        try {
            Method m = ScanResult.class.getMethod("getChannelWidth");
            Object value = m.invoke(result);
            if (value instanceof Integer) return widthText((Integer) value);
        } catch (Exception ignored) { }
        return "未知";
    }

    private static String connectedWidth(WifiInfo info) {
        if (info == null) return null;
        try {
            Method m = WifiInfo.class.getMethod("getChannelWidth");
            Object value = m.invoke(info);
            if (value instanceof Integer) return widthText((Integer) value);
        } catch (Exception ignored) { }
        return null;
    }

    private static String widthText(int w) {
        if (w >= 20 && w <= 320) return w + " MHz";
        switch (w) {
            case 0: return "20 MHz";
            case 1: return "40 MHz";
            case 2: return "80 MHz";
            case 3: return "160 MHz";
            case 4: return "80+80 MHz";
            case 5: return "320 MHz";
            default: return "未知";
        }
    }

    private static int frequencyToChannel(int freq) {
        if (freq >= 2412 && freq <= 2472) return (freq - 2407) / 5;
        if (freq == 2484) return 14;
        if (freq >= 5000 && freq < 5900) return (freq - 5000) / 5;
        if (freq >= 5900) return (freq - 5950) / 5;
        return 0;
    }

    private static String bandOf(int freq) {
        if (freq >= 5900) return "6 GHz";
        if (freq >= 4900) return "5 GHz";
        if (freq > 0) return "2.4 GHz";
        return "未知";
    }

    private static String securityOf(String capabilities) {
        if (capabilities == null) return "未知";
        String c = capabilities.toUpperCase();
        if (c.contains("WPA3")) return "WPA3";
        if (c.contains("WPA2")) return "WPA2";
        if (c.contains("WPA")) return "WPA";
        if (c.contains("WEP")) return "WEP";
        return "开放";
    }
}

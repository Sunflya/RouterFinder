package com.sunflya.routerfinder;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;

public class MainActivity extends Activity {
    private Button scanButton;
    private TextView statusText;
    private TextView summaryText;
    private LinearLayout listBox;
    private final Handler main = new Handler(Looper.getMainLooper());
    private volatile boolean scanning = false;
    private List<Device> devices = new ArrayList<>();

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setTitle("路由器探测");

        ScrollView scroll = new ScrollView(this);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(28, 32, 28, 48);
        scroll.addView(root, new ScrollView.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        TextView title = new TextView(this);
        title.setText("局域网路由器探测");
        title.setTextSize(22);
        title.setTextColor(Color.rgb(20, 28, 60));
        title.setGravity(Gravity.CENTER_HORIZONTAL);
        root.addView(title);

        TextView sub = new TextView(this);
        sub.setText("端口指纹 + 主动 DHCP 握手，准确识别 DHCP 服务器");
        sub.setTextSize(13);
        sub.setTextColor(Color.rgb(100, 110, 135));
        sub.setGravity(Gravity.CENTER_HORIZONTAL);
        LinearLayout.LayoutParams subLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        subLp.setMargins(0, 8, 0, 24);
        root.addView(sub, subLp);

        scanButton = new Button(this);
        scanButton.setText("开始扫描局域网");
        scanButton.setTextSize(16);
        scanButton.setBackgroundColor(Color.rgb(41, 98, 255));
        scanButton.setTextColor(Color.WHITE);
        root.addView(scanButton, ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT);
        scanButton.setOnClickListener(v -> startScan());

        statusText = new TextView(this);
        statusText.setText("就绪 · 请连接 Wi-Fi 后扫描");
        statusText.setTextSize(14);
        statusText.setTextColor(Color.rgb(70, 80, 105));
        LinearLayout.LayoutParams stLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        stLp.setMargins(0, 16, 0, 8);
        root.addView(statusText, stLp);

        summaryText = new TextView(this);
        summaryText.setText("");
        summaryText.setTextSize(13);
        summaryText.setTextColor(Color.rgb(90, 100, 125));
        root.addView(summaryText);

        listBox = new LinearLayout(this);
        listBox.setOrientation(LinearLayout.VERTICAL);
        root.addView(listBox, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        setContentView(scroll);

        if (Build.VERSION.SDK_INT >= 23
                && checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
                != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.ACCESS_FINE_LOCATION}, 100);
        }
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] perms, int[] results) {
        super.onRequestPermissionsResult(code, perms, results);
        if (code == 100 && results.length > 0 && results[0] != PackageManager.PERMISSION_GRANTED) {
            Toast.makeText(this, "需要位置权限才能读取 Wi-Fi 信息", Toast.LENGTH_LONG).show();
        }
    }

    private void startScan() {
        if (scanning) return;
        if (Build.VERSION.SDK_INT >= 23
                && checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
                != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.ACCESS_FINE_LOCATION}, 100);
            Toast.makeText(this, "请先允许位置权限", Toast.LENGTH_SHORT).show();
            return;
        }
        scanning = true;
        scanButton.setEnabled(false);
        listBox.removeAllViews();
        devices = new ArrayList<>();
        statusText.setText("正在读取网络信息…");

        new Thread(() -> {
            final NetworkInfo info = NetworkInfo.from(this);
            if (info == null) {
                main.post(() -> finishScan("未检测到 Wi-Fi 连接，请连接局域网后重试"));
                return;
            }
            main.post(() -> statusText.setText("网段 " + info.netAddress + "/" + info.prefix
                    + " · 网关 " + info.gateway + " · 正在扫描设备…"));

            final List<Device> found = new SubnetScanner().scan(info, (done, total, text) ->
                    main.post(() -> statusText.setText(text)));

            // Fill MAC addresses from ARP cache
            Map<String, String> arp = SubnetScanner.readArp();
            for (Device d : found) d.mac = arp.get(d.ip);

            // Active DHCP probe via broadcast; option 54 tells us the real server
            main.post(() -> statusText.setText("正在发送 DHCP Discover 探测服务器…"));
            DhcpProber.Result dhcp = DhcpProber.probe(getApplicationContext(), "255.255.255.255");
            boolean matched = false;
            for (Device d : found) {
                if (dhcp.detected && dhcp.serverId != null && dhcp.serverId.equals(d.ip)) {
                    applyDhcp(d, dhcp);
                    matched = true;
                }
            }
            if (dhcp.detected && !matched && dhcp.serverId != null) {
                Device server = new Device(dhcp.serverId);
                server.hostname = "DHCP 服务器";
                server.sources.add("DHCP 探测");
                if (dhcp.serverId.equals(info.gateway)) {
                    server.likelyRouter = true;
                    server.hostname = "网关 / DHCP 服务器";
                }
                applyDhcp(server, dhcp);
                found.add(server);
            }
            Collections.sort(found, (a, b) -> {
                if (a.likelyRouter != b.likelyRouter) return a.likelyRouter ? -1 : 1;
                int pc = Integer.compare(b.openPorts.size(), a.openPorts.size());
                if (pc != 0) return pc;
                return a.ip.compareTo(b.ip);
            });

            final String msg = dhcp.detected
                    ? "DHCP 服务器: " + dhcp.serverId
                    : "未收到 DHCP Offer（可在设备详情里单独复测）";
            main.post(() -> {
                devices = found;
                renderList();
                summaryText.setText("发现 " + found.size() + " 台设备 · " + msg);
                statusText.setText("扫描完成");
                finishScan(null);
            });
        }).start();
    }

    private void finishScan(String error) {
        scanning = false;
        scanButton.setEnabled(true);
        scanButton.setText("重新扫描");
        if (error != null) {
            statusText.setText(error);
            Toast.makeText(this, error, Toast.LENGTH_LONG).show();
        }
    }

    private static void applyDhcp(Device d, DhcpProber.Result r) {
        if (r.detected) {
            d.dhcpState = Device.DhcpState.YES;
            d.dhcpServerId = r.serverId;
            d.dhcpOfferedIp = r.offeredIp;
            d.dhcpMask = r.subnetMask;
            d.dhcpGateway = r.gateway;
            d.dhcpDns = r.dns;
            d.dhcpLease = r.leaseSeconds;
        } else {
            d.dhcpState = Device.DhcpState.FAILED;
        }
        d.dhcpDetail = r.detail;
    }

    private void renderList() {
        listBox.removeAllViews();
        if (devices.isEmpty()) {
            TextView empty = new TextView(this);
            empty.setText("没有发现设备。请确认连的是主 Wi-Fi（非访客网络），且未开启 AP 隔离。");
            empty.setTextColor(Color.rgb(110, 115, 130));
            listBox.addView(empty);
            return;
        }
        for (final Device d : devices) {
            TextView row = new TextView(this);
            String badge = "";
            if (d.dhcpState == Device.DhcpState.YES) {
                badge = "  DHCP ✓";
                row.setTextColor(Color.rgb(0, 120, 70));
            } else if (d.likelyRouter) {
                badge = "  疑似路由器";
                row.setTextColor(Color.rgb(180, 100, 0));
            } else {
                row.setTextColor(Color.rgb(35, 45, 75));
            }
            row.setText(d.ip + (d.hostname != null ? "  · " + d.hostname : "") + badge
                    + "\n端口: " + d.portsText());
            row.setTextSize(14);
            row.setPadding(20, 16, 20, 16);
            GradientDrawable bg = new GradientDrawable();
            bg.setColor(Color.WHITE);
            bg.setCornerRadius(14);
            bg.setStroke(1, Color.rgb(222, 228, 240));
            row.setBackground(bg);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            lp.setMargins(0, 0, 0, 10);
            listBox.addView(row, lp);
            row.setOnClickListener(v -> showDetail(d));
        }
    }

    private void showDetail(final Device d) {
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(8, 8, 8, 8);

        addInfo(box, "IP 地址", d.ip);
        addInfo(box, "主机名", d.hostname == null ? "未知" : d.hostname);
        addInfo(box, "MAC 地址", d.mac == null ? "未获取（ARP 缓存中没有）" : d.mac);
        addInfo(box, "开放端口", d.portsText());
        addInfo(box, "发现方式", d.sources.isEmpty() ? "未知" : String.join("、", d.sources));

        String dhcpTitle;
        switch (d.dhcpState) {
            case YES: dhcpTitle = "已确认开启 DHCP 服务器  ✓"; break;
            case FAILED: dhcpTitle = "未检测到 DHCP Offer"; break;
            default: dhcpTitle = "尚未检测"; break;
        }
        TextView h = new TextView(this);
        h.setText("DHCP 检测：" + dhcpTitle);
        h.setTextSize(16);
        h.setTextColor(d.dhcpState == Device.DhcpState.YES
                ? Color.rgb(0, 130, 75) : Color.rgb(150, 80, 0));
        LinearLayout.LayoutParams hp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        hp.setMargins(0, 24, 0, 8);
        box.addView(h, hp);

        if (d.dhcpState == Device.DhcpState.YES) {
            addInfo(box, "服务器标识", d.dhcpServerId == null ? "未知" : d.dhcpServerId);
            addInfo(box, "下发地址", d.dhcpOfferedIp == null ? "未知" : d.dhcpOfferedIp);
            addInfo(box, "子网掩码", d.dhcpMask == null ? "未知" : d.dhcpMask);
            addInfo(box, "网关", d.dhcpGateway == null ? "未知" : d.dhcpGateway);
            addInfo(box, "DNS", d.dhcpDns == null ? "未知" : d.dhcpDns);
            if (d.dhcpLease > 0) addInfo(box, "租约时长", formatLease(d.dhcpLease));
        }
        if (d.dhcpDetail != null) addInfo(box, "诊断", d.dhcpDetail);

        Button recheck = new Button(this);
        recheck.setText("重新检测这台设备的 DHCP");
        LinearLayout.LayoutParams bp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        bp.setMargins(0, 20, 0, 8);
        box.addView(recheck, bp);

        Button openWeb = new Button(this);
        openWeb.setText("在浏览器打开管理页");
        box.addView(openWeb, bp);
        Button copy = new Button(this);
        copy.setText("复制 IP");
        box.addView(copy, bp);

        ScrollView sv = new ScrollView(this);
        sv.addView(box);
        final AlertDialog dialog = new AlertDialog.Builder(this)
                .setTitle(d.ip + (d.likelyRouter ? " · 疑似路由器" : ""))
                .setView(sv)
                .setPositiveButton("关闭", null)
                .create();

        recheck.setOnClickListener(v -> {
            recheck.setEnabled(false);
            recheck.setText("检测中…");
            new Thread(() -> {
                final DhcpProber.Result r = DhcpProber.probe(getApplicationContext(), d.ip);
                main.post(() -> {
                    applyDhcp(d, r);
                    dialog.dismiss();
                    renderList();
                    showDetail(d);
                });
            }).start();
        });
        openWeb.setOnClickListener(v -> {
            try {
                startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse("http://" + d.ip)));
            } catch (Exception e) {
                Toast.makeText(this, "无法打开浏览器", Toast.LENGTH_SHORT).show();
            }
        });
        copy.setOnClickListener(v -> {
            ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
            if (cm != null) cm.setPrimaryClip(ClipData.newPlainText("ip", d.ip));
            Toast.makeText(this, "已复制 " + d.ip, Toast.LENGTH_SHORT).show();
        });
        dialog.show();
    }

    private void addInfo(LinearLayout box, String key, String value) {
        TextView t = new TextView(this);
        t.setText(key + "：" + value);
        t.setTextSize(14);
        t.setTextColor(Color.rgb(50, 60, 85));
        t.setPadding(0, 5, 0, 5);
        box.addView(t);
    }

    private static String formatLease(int seconds) {
        if (seconds >= 86400) return (seconds / 86400) + " 天";
        if (seconds >= 3600) return (seconds / 3600) + " 小时";
        return seconds + " 秒";
    }
}

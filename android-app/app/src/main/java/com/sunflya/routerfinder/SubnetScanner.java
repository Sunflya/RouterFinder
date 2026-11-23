package com.sunflya.routerfinder;

import java.io.BufferedReader;
import java.io.FileReader;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicInteger;

public class SubnetScanner {
    public interface Progress {
        void onProgress(int done, int total, String text);
    }

    private static final int[] PORTS = {80, 443, 8080, 1900, 53, 22, 23};
    private static final int[] QUICK_PORTS = {80, 443, 1900};

    /**
     * 两阶段扫描：先用三个高命中端口快速找出活跃主机，再只对它们做完整端口指纹。
     * 相比对 254 个 IP 逐个扫 7 个端口，速度提升数倍。
     */
    public List<Device> scan(NetworkInfo info, Progress progress) {
        Set<String> candidates = new LinkedHashSet<>(info.hostIps());
        candidates.add(info.gateway);

        // ---------- 阶段 1：快速存活探测 ----------
        final Set<String> alive = Collections.synchronizedSet(new HashSet<String>());
        ExecutorService quickPool = Executors.newFixedThreadPool(96);
        List<Future<?>> quickTasks = new ArrayList<>();
        final AtomicInteger quickDone = new AtomicInteger(0);
        final int quickTotal = candidates.size() * QUICK_PORTS.length;

        for (final String ip : candidates) {
            for (final int port : QUICK_PORTS) {
                quickTasks.add(quickPool.submit(() -> {
                    if (isPortOpen(ip, port, 130)) alive.add(ip);
                    int n = quickDone.incrementAndGet();
                    if (progress != null && (n % 30 == 0 || n == quickTotal)) {
                        progress.onProgress(n, quickTotal, "快速发现 " + n + "/" + quickTotal);
                    }
                }));
            }
        }
        for (Future<?> f : quickTasks) {
            try { f.get(); } catch (Exception ignored) { }
        }
        quickPool.shutdownNow();

        // 网关必定进入第二阶段
        alive.add(info.gateway);

        // ---------- 阶段 2：只对活跃主机做完整端口指纹 ----------
        List<String> targets = new ArrayList<>(alive);
        Collections.sort(targets);
        final Map<String, List<Integer>> portsByHost = Collections.synchronizedMap(new HashMap<String, List<Integer>>());
        ExecutorService fullPool = Executors.newFixedThreadPool(64);
        List<Future<?>> fullTasks = new ArrayList<>();
        final AtomicInteger fullDone = new AtomicInteger(0);
        final int fullTotal = targets.size() * PORTS.length;

        for (final String ip : targets) {
            for (final int port : PORTS) {
                fullTasks.add(fullPool.submit(() -> {
                    if (isPortOpen(ip, port, 180)) {
                        List<Integer> list = portsByHost.get(ip);
                        if (list == null) {
                            list = Collections.synchronizedList(new ArrayList<Integer>());
                            portsByHost.put(ip, list);
                        }
                        list.add(port);
                    }
                    int n = fullDone.incrementAndGet();
                    if (progress != null && (n % 20 == 0 || n == fullTotal)) {
                        progress.onProgress(n, fullTotal, "端口指纹 " + n + "/" + fullTotal);
                    }
                }));
            }
        }
        for (Future<?> f : fullTasks) {
            try { f.get(); } catch (Exception ignored) { }
        }
        fullPool.shutdownNow();

        List<Device> out = new ArrayList<>();
        for (Map.Entry<String, List<Integer>> e : portsByHost.entrySet()) {
            Device d = new Device(e.getKey());
            d.openPorts.addAll(e.getValue());
            Collections.sort(d.openPorts);
            d.sources.add("端口扫描");
            if (e.getKey().equals(info.gateway)) {
                d.hostname = "网关";
                d.sources.add(0, "网关推断");
                d.likelyRouter = true;
            } else {
                d.likelyRouter = d.openPorts.contains(1900)
                        || (d.openPorts.contains(53) && (d.openPorts.contains(80)
                        || d.openPorts.contains(443) || d.openPorts.contains(8080)));
            }
            out.add(d);
        }
        boolean hasGateway = false;
        for (Device d : out) if (d.ip.equals(info.gateway)) hasGateway = true;
        if (!hasGateway) {
            Device gw = new Device(info.gateway);
            gw.hostname = "网关";
            gw.likelyRouter = true;
            gw.sources.add("网关推断");
            out.add(gw);
        }

        Collections.sort(out, new Comparator<Device>() {
            @Override
            public int compare(Device a, Device b) {
                if (a.likelyRouter != b.likelyRouter) return a.likelyRouter ? -1 : 1;
                int pc = Integer.compare(b.openPorts.size(), a.openPorts.size());
                if (pc != 0) return pc;
                return a.ip.compareTo(b.ip);
            }
        });
        return out;
    }

    private static boolean isPortOpen(String ip, int port, int timeoutMs) {
        Socket s = new Socket();
        try {
            s.connect(new InetSocketAddress(ip, port), timeoutMs);
            return true;
        } catch (Exception e) {
            return false;
        } finally {
            try { s.close(); } catch (Exception ignored) { }
        }
    }

    /** Best-effort MAC addresses from the kernel ARP cache. */
    public static Map<String, String> readArp() {
        Map<String, String> map = new HashMap<>();
        try (BufferedReader r = new BufferedReader(new FileReader("/proc/net/arp"))) {
            String line = r.readLine();
            while ((line = r.readLine()) != null) {
                String[] p = line.trim().split("\\s+");
                if (p.length >= 4 && !"0x0".equals(p[2])) {
                    map.put(p[0], p[3].toUpperCase());
                }
            }
        } catch (Exception ignored) { }
        return map;
    }
}

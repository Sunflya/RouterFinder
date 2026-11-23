package com.sunflya.routerfinder;

import java.io.BufferedReader;
import java.io.FileReader;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicInteger;

public class SubnetScanner {
    public interface Progress {
        void onProgress(int done, int total, String text);
    }

    private static final int[] PORTS = {80, 443, 8080, 1900, 53, 22, 23};

    public List<Device> scan(NetworkInfo info, Progress progress) {
        final List<String> ips = info.hostIps();
        final List<Device> results = Collections.synchronizedList(new ArrayList<Device>());
        final AtomicInteger done = new AtomicInteger(0);
        ExecutorService pool = Executors.newFixedThreadPool(48);
        List<Future<?>> futures = new ArrayList<>();

        for (final String ip : ips) {
            futures.add(pool.submit(() -> {
                Device d = probe(ip, info.gateway);
                if (d != null) results.add(d);
                int n = done.incrementAndGet();
                if (progress != null && (n % 8 == 0 || n == ips.size())) {
                    progress.onProgress(n, ips.size(), "扫描中 " + n + "/" + ips.size());
                }
            }));
        }
        for (Future<?> f : futures) {
            try { f.get(); } catch (Exception ignored) { }
        }
        pool.shutdownNow();

        List<Device> out = new ArrayList<>(results);
        Collections.sort(out, (a, b) -> {
            if (a.likelyRouter != b.likelyRouter) return a.likelyRouter ? -1 : 1;
            int pc = Integer.compare(b.openPorts.size(), a.openPorts.size());
            if (pc != 0) return pc;
            return a.ip.compareTo(b.ip);
        });
        return out;
    }

    private static Device probe(String ip, String gateway) {
        List<Integer> open = new ArrayList<>();
        for (int port : PORTS) {
            if (isPortOpen(ip, port)) open.add(port);
        }
        if (open.isEmpty()) return null;
        Device d = new Device(ip);
        d.openPorts.addAll(open);
        d.sources.add("端口扫描");
        if (ip.equals(gateway)) {
            d.hostname = "网关";
            d.sources.add(0, "网关推断");
            d.likelyRouter = true;
        } else {
            d.likelyRouter = open.contains(1900)
                    || (open.contains(53) && (open.contains(80) || open.contains(443) || open.contains(8080)));
        }
        return d;
    }

    private static boolean isPortOpen(String ip, int port) {
        Socket s = new Socket();
        try {
            s.connect(new InetSocketAddress(ip, port), 220);
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

package com.abouhilalbadr.quiethome;

import android.content.Context;
import android.graphics.Color;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

// settings.conf, packed into the app by build.sh. One "key = value" per line; lines starting with # are
// comments. A missing file or key falls back to the default the caller passes, so the home screen always starts.
final class Conf {
    private final Map<String, String> values = new HashMap<>();

    static Conf load(Context c) {
        Conf conf = new Conf();
        try (BufferedReader in = new BufferedReader(new InputStreamReader(
                c.getAssets().open("settings.conf"), StandardCharsets.UTF_8))) {
            String line;
            while ((line = in.readLine()) != null) {
                line = line.trim();
                int eq = line.indexOf('=');
                if (line.isEmpty() || line.startsWith("#") || eq <= 0) continue;
                conf.values.put(line.substring(0, eq).trim().toLowerCase(Locale.ROOT), line.substring(eq + 1).trim());
            }
        } catch (Exception ignored) {}
        return conf;
    }

    String get(String key, String fallback) {
        String v = values.get(key);
        return v != null ? v : fallback;
    }

    // A comma-separated list, lower-cased when lower is true. An empty value is an empty list.
    List<String> list(String key, String fallback, boolean lower) {
        List<String> out = new ArrayList<>();
        for (String item : get(key, fallback).split("[,\\s]+")) {
            if (item.isEmpty()) continue;
            String v = lower ? item.toLowerCase(Locale.ROOT) : item;
            if (!out.contains(v)) out.add(v);
        }
        return out;
    }

    boolean yes(String key, boolean fallback) {
        String v = get(key, "").toLowerCase(Locale.ROOT);
        if (v.equals("yes") || v.equals("on") || v.equals("true")) return true;
        if (v.equals("no") || v.equals("off") || v.equals("false")) return false;
        return fallback;
    }

    // #RRGGBB (or a colour name Android knows, like "white"); anything else gives the fallback.
    int color(String key, int fallback) {
        try { return Color.parseColor(get(key, "")); }
        catch (Exception e) { return fallback; }
    }
}

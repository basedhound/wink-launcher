// Search engine: scores every entry against the typed text (instant even with hundreds of entries).
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

public static class LauncherSearch {
    // Comparison key: lower case, accents removed ("Cafe" with an accent matches "cafe")
    public static string Key(string s) {
        var d = (s ?? "").ToLowerInvariant().Normalize(NormalizationForm.FormD);
        var sb = new StringBuilder(d.Length);
        foreach (char c in d) if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark) sb.Append(c);
        return sb.ToString();
    }

    static readonly char[] Sep = { ' ', '-', '_', '.', '(', ')' };
    const int Strong = 200;   // scores from here on: the name, a word of it or its initials start like the text

    // How well name key n matches text q (0: not at all). Weak matches (< Strong) only count when nothing strong matches.
    public static int Score(string n, string q) {
        if (n == q) return 1000;
        if (n.StartsWith(q, StringComparison.Ordinal)) return 800;
        var words = n.Split(Sep, StringSplitOptions.RemoveEmptyEntries);
        if (string.Concat(words).StartsWith(q, StringComparison.Ordinal)) return 700;   // "wifi" -> "Wi-Fi"
        int word = WordStartScore(n, q);
        if (word > 0) return word;
        if (q.Length >= 2 && Initials(words).StartsWith(q, StringComparison.Ordinal)) return 450;   // "vsc" -> Visual Studio Code
        if (n.IndexOf(q, StringComparison.Ordinal) >= 0) return 150;   // inside a word (weak)
        return LettersInOrder(n, q) ? 100 : 0;
    }

    // The text starting at a word (several words allowed: "hidden files"); the earlier the word, the better
    // ("YouTube Playlist" before "VLC media player")
    static int WordStartScore(string n, string q) {
        for (int p = n.IndexOf(q, StringComparison.Ordinal); p >= 0; p = n.IndexOf(q, p + 1, StringComparison.Ordinal))
            if (p == 0 || Array.IndexOf(Sep, n[p - 1]) >= 0)
                return 600 - 20 * Math.Min(n.Substring(0, p).Split(Sep, StringSplitOptions.RemoveEmptyEntries).Length, 5);
        return 0;
    }

    static string Initials(string[] words) {
        var ini = new StringBuilder();
        foreach (var w in words) ini.Append(w[0]);
        return ini.ToString();
    }

    // Letters in order, starting at the beginning of a word: "ntpd" -> Notepad,
    // but not "sarv" -> windowS AdministRatiVe Tools (letters picked from anywhere in a long name)
    static bool LettersInOrder(string n, string q) {
        for (int p = 0; p < n.Length; p++) {
            if (n[p] != q[0] || (p > 0 && Array.IndexOf(Sep, n[p - 1]) < 0)) continue;
            int i = 0;
            for (int k = p; k < n.Length && i < q.Length; k++) if (n[k] == q[i]) i++;
            if (i == q.Length) return true;
        }
        return false;
    }

    // Best entries for the typed text, as indexes into keys (at most max).
    //   aliases[i]: the entry's aliases separated by '|'
    //   hits[i]:    how many times it was launched (frequent ones rank higher)
    //   bonus[i]:   ranking offset for its kind (apps 0, Control Panel and Settings negative)
    //   groups[i]:  "" for normal results, or a prefix ("steam", "gog") for entries searched only after it:
    //               "steam e" searches Steam games for "e", "steam " lists them all; elsewhere they only answer to their aliases
    public static int[] Find(string[] keys, string[] aliases, int[] hits, int[] bonus, string[] groups, string text, int max) {
        string grp;
        string q = SplitGroup(Key((text ?? "").TrimStart()), groups, out grp);
        var strong = new List<int[]>();   // { index, score }
        var weak = new List<int[]>();
        for (int i = 0; i < keys.Length; i++) {
            if (groups[i] != grp && (grp.Length > 0 || q.Length == 0)) continue;
            int s = groups[i] != grp ? 0 : q.Length == 0 ? 1 : Score(keys[i], q);
            if (q.Length > 0) s = Math.Max(s, AliasScore(aliases[i], q));
            if (s <= 0) continue;
            var r = new[] { i, Math.Max(1, s + bonus[i]) + Math.Min(300, 25 * hits[i]) };
            if (q.Length == 0 || s >= Strong) strong.Add(r);
            else if (bonus[i] == 0) weak.Add(r);   // weak matches: apps and shortcuts only
        }
        var res = strong.Count > 0 ? strong : weak;
        // best score first, then the shortest name (Excel before Exceed Share); a full list ("steam ") is alphabetical
        res.Sort((x, y) => y[1] != x[1] ? y[1].CompareTo(x[1])
                         : q.Length > 0 && keys[x[0]].Length != keys[y[0]].Length ? keys[x[0]].Length.CompareTo(keys[y[0]].Length)
                         : string.CompareOrdinal(keys[x[0]], keys[y[0]]));
        var o = new int[Math.Min(max, res.Count)];
        for (int i = 0; i < o.Length; i++) o[i] = res[i][0];
        return o;
    }

    // "steam dark" -> group "steam", text "dark"; no known prefix -> group "", text unchanged (trimmed)
    static string SplitGroup(string q, string[] groups, out string grp) {
        grp = "";
        foreach (var g in groups)
            if (g.Length > 0 && q.StartsWith(g + " ", StringComparison.Ordinal)) { grp = g; return q.Substring(g.Length + 1).Trim(); }
        return q.Trim();
    }

    static int AliasScore(string aliases, string q) {
        if (aliases.Length == 0) return 0;
        int s = 0;
        foreach (var a in aliases.Split('|')) {
            if (a == q) return 2000;
            if (a.StartsWith(q, StringComparison.Ordinal)) s = 900;
        }
        return s;
    }
}

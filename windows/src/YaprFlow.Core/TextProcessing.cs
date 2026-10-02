using System.Text.RegularExpressions;

namespace YaprFlow.Core;

public static class TextProcessing
{
    private static string Replace(string text, string pattern, string replacement) =>
        Regex.Replace(text, pattern, replacement, RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));

    public static string Cleanup(string input)
    {
        var text = Replace(input, @"[ \t]{2,}", " ");
        text = Replace(text, @"[ \t]+([,.;:!?])", "$1");
        text = Replace(text, @"([,;:])\1+", "$1");
        text = Replace(text, @"\n[ \t]*\n(?:[ \t]*\n)+", "\n\n");
        while (true)
        {
            var next = Replace(text, @"(?i)\b(the|a|an|of|and|i)\b([ \t]+)\1\b", "$1");
            if (next == text) return text.Trim();
            text = next;
        }
    }

    public static string ApplyVocabulary(string text, IEnumerable<VocabularyRule> rules)
    {
        // One pass prevents a replacement from becoming input to another rule.
        var map = rules.Where(r => !string.IsNullOrWhiteSpace(r.Heard) && !string.IsNullOrWhiteSpace(r.Replacement))
            .GroupBy(r => r.Heard.Trim(), StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.Last().Replacement.Trim(), StringComparer.OrdinalIgnoreCase);
        if (map.Count == 0) return text;
        var alternatives = string.Join("|", map.Keys.OrderByDescending(k => k.Length).Select(Regex.Escape));
        return Regex.Replace(text, $@"(?<![\p{{L}}\p{{N}}_])(?:{alternatives})(?![\p{{L}}\p{{N}}_])",
            m => map[m.Value], RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
    }

    public static void ValidateVocabulary(IReadOnlyList<VocabularyRule> rules)
    {
        if (rules.Count > 500 || rules.Any(r => r is null || string.IsNullOrWhiteSpace(r.Heard) ||
            string.IsNullOrWhiteSpace(r.Replacement) || r.Heard.Length > 200 || r.Replacement.Length > 200) ||
            rules.GroupBy(r => r.Heard.Trim(), StringComparer.OrdinalIgnoreCase).Any(g => g.Count() > 1))
            throw new InvalidDataException("Use up to 500 unique phrases, with 1–200 characters in each field.");
    }
}

using System.Text.RegularExpressions;
namespace YaprFlow.Core;
public static class CorrectionInference
{
    // Suggest one small word/phrase replacement; broad rewrites and numeric edits are ignored.
    public static VocabularyRule? Infer(string original, string edited)
    {
        if (original.Length > 4000 || edited.Length > 4000 || original == edited) return null;
        var a = Regex.Matches(original, @"[\p{L}\p{N}'’-]+|[^\s]").Select(m => m.Value).ToArray();
        var b = Regex.Matches(edited, @"[\p{L}\p{N}'’-]+|[^\s]").Select(m => m.Value).ToArray();
        int start = 0, end = 0;
        while (start < a.Length && start < b.Length && a[start] == b[start]) start++;
        while (end < a.Length - start && end < b.Length - start && a[^(end + 1)] == b[^(end + 1)]) end++;
        var before = a.Skip(start).Take(a.Length - start - end).ToArray();
        var after = b.Skip(start).Take(b.Length - start - end).ToArray();
        if (before.Length is < 1 or > 3 || after.Length is < 1 or > 3 ||
            before.Concat(after).Any(w => !Regex.IsMatch(w, @"^\p{L}[\p{L}'’-]*$"))) return null;
        var heard = string.Join(" ", before); var replacement = string.Join(" ", after);
        if (heard.Length > 80 || replacement.Length > 80) return null;
        return new(heard, replacement);
    }
    public static string? EditedSpan(string baseline, string original, string updated)
    {
        if (baseline.Length > 12000 || updated.Length > 12000 || string.IsNullOrWhiteSpace(original)) return null;
        var at = baseline.IndexOf(original, StringComparison.Ordinal);
        if (at < 0 || baseline.IndexOf(original, at + original.Length, StringComparison.Ordinal) >= 0) return null;
        var prefix = baseline[..at]; var suffix = baseline[(at + original.Length)..];
        if (!updated.StartsWith(prefix, StringComparison.Ordinal) || !updated.EndsWith(suffix, StringComparison.Ordinal) ||
            updated.Length < prefix.Length + suffix.Length) return null;
        return updated.Substring(prefix.Length, updated.Length - prefix.Length - suffix.Length);
    }
}

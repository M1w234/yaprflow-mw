using System.Text.RegularExpressions;
namespace YaprFlow.Core;
public interface ITextPolisher { Task<string> PolishAsync(string text, CancellationToken token); }
public static class PolishGuard
{
    public static string Validate(string original, string output)
    {
        output = output.Trim();
        var oldWords = original.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
        var newWords = output.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
        var numbers = (string s) => Regex.Matches(s, @"\d+(?:[.,]\d+)*").Select(m => m.Value).ToArray();
        if (output.Length == 0 || output.Contains("<think", StringComparison.OrdinalIgnoreCase) || output.Contains("<|") ||
            output.Contains("```", StringComparison.Ordinal) || newWords < Math.Max(1, oldWords * .65) || newWords > oldWords * 1.35 + 3 ||
            !numbers(original).SequenceEqual(numbers(output)))
            throw new InvalidDataException("AI Polish changed too much; original retained.");
        return output;
    }
}

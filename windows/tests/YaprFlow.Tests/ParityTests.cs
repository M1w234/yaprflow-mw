using Xunit;
using YaprFlow.Core;
namespace YaprFlow.Tests;
public class ParityTests
{
    [Fact] public void ModifierHoldRequiresDwellAndStopsOnRelease()
    {
        var s = new ModifierGestureState(ModifierGesture.LeftCtrlShift, true);
        s.Key(0xA2, true, 0); s.Key(0xA0, true, 10);
        Assert.Equal(GestureAction.None, s.Tick(100)); Assert.Equal(GestureAction.StartHold, s.Tick(200));
        Assert.Equal(GestureAction.Finish, s.Key(0xA0, false, 250));
    }
    [Theory] [InlineData(0x41)] [InlineData(0xA4)] [InlineData(0xA3)]
    public void OtherKeysRejectModifierGesture(int key)
    {
        var s = new ModifierGestureState(ModifierGesture.LeftCtrlShift, true);
        s.Key(0xA2, true, 0); s.Key(0xA0, true, 10); s.Key(key, true, 50);
        Assert.Equal(GestureAction.None, s.Tick(300));
        Assert.Equal(GestureAction.None, s.Key(0xA0, false, 310));
    }
    [Fact] public void OtherKeyCancelsAnActiveHold()
    {
        var s = new ModifierGestureState(ModifierGesture.LeftCtrlShift, true);
        s.Key(0xA2, true, 0); s.Key(0xA0, true, 10); s.Tick(200);
        Assert.Equal(GestureAction.Cancel, s.Key(0x41, true, 300));
    }
    [Fact] public void WrongSideDoesNotTrigger()
    {
        var s = new ModifierGestureState(ModifierGesture.LeftCtrlShift, true);
        s.Key(0xA3, true, 0); s.Key(0xA1, true, 10); Assert.Equal(GestureAction.None, s.Tick(200));
    }
    [Fact] public void DoubleTapLocksAndNextTapFinishes()
    {
        var s = new ModifierGestureState(ModifierGesture.RightCtrlShift, true);
        GestureAction Tap(long now)
        {
            s.Key(0xA3, true, now); s.Key(0xA1, true, now + 10);
            var action = s.Key(0xA1, false, now + 50); s.Key(0xA3, false, now + 60); return action;
        }
        Assert.Equal(GestureAction.None, Tap(0)); Assert.Equal(GestureAction.StartLocked, Tap(180));
        s.Key(0x41, true, 300); s.Key(0x41, false, 320); // Ordinary typing must not stop locked recording.
        Assert.Equal(GestureAction.Finish, Tap(500));
    }
    [Fact] public void DisabledDoubleTapNeverLocks()
    {
        var s = new ModifierGestureState(ModifierGesture.LeftCtrlShift, false);
        for (int i = 0; i < 2; i++) { s.Key(0xA2, true, i * 100); s.Key(0xA0, true, i * 100 + 5); Assert.Equal(GestureAction.None, s.Key(0xA0, false, i * 100 + 30)); s.Key(0xA2, false, i * 100 + 40); }
    }
    [Theory]
    [InlineData("Ask clod tomorrow.", "Ask Claude tomorrow.", "clod", "Claude")]
    [InlineData("Use new construction hawaii.", "Use New Construction Hawaii.", "new construction hawaii", "New Construction Hawaii")]
    public void SmallCorrectionsProduceReviewableRules(string a, string b, string heard, string replacement)
        => Assert.Equal(new VocabularyRule(heard, replacement), CorrectionInference.Infer(a, b));
    [Theory] [InlineData("Pay 20 dollars", "Pay 200 dollars")]
    [InlineData("Call Mike", "Call")]
    [InlineData("One two three four five", "Six seven eight nine ten")]
    [InlineData("Hello.", "Hello!")]
    public void BroadOrNumericEditsAreNotLearned(string a, string b) => Assert.Null(CorrectionInference.Infer(a, b));
    [Fact] public void LearningRequiresUnchangedSurroundingTextAndUniqueSpan()
    {
        Assert.Equal("Ask Claude.", CorrectionInference.EditedSpan("Before Ask clod. After", "Ask clod.", "Before Ask Claude. After"));
        Assert.Null(CorrectionInference.EditedSpan("Before Ask clod. After", "Ask clod.", "Changed Ask Claude. After"));
        Assert.Null(CorrectionInference.EditedSpan("Hello Hello", "Hello", "Hello hi"));
    }
    [Fact] public void PolishProtectsNumbersAndRejectsEmptyOrExpandedAnswers()
    {
        Assert.Equal("Pay 20 dollars.", PolishGuard.Validate("pay 20 dollars", "Pay 20 dollars."));
        Assert.Throws<InvalidDataException>(() => PolishGuard.Validate("pay 20 dollars", "Pay 200 dollars."));
        Assert.Throws<InvalidDataException>(() => PolishGuard.Validate("hello", ""));
        Assert.Throws<InvalidDataException>(() => PolishGuard.Validate("hello", "Here is an elaborate answer to your request which I will now explain."));
    }
}

"""Emit Swift golden literals for the WispritRefine port by running the REAL
wisprit/refine.py. See the comment headers in the generated Swift test files."""
import sys
sys.path.insert(0, "/Users/shariquekhatri/Wisprit")
from wisprit.refine import (
    _has_address, _plausible, _strip_wrappers, _estimated_words, _first_content_word,
)


def lit(s):
    out = ['"']
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\t":
            out.append("\\t")
        elif ord(ch) < 0x20:
            out.append("\\u{%X}" % ord(ch))
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


WRAPPERS = [
    "So the migration went fine.",
    "```\nThe cleaned text.\n```",
    "```text\nThe cleaned text.\n```",
    "<transcript>\nthe endpoint is ready\n</transcript>",
    "<cleaned_text>Hello there.</cleaned_text>",
    '"Just a quoted line."',
    "'Single quoted line.'",
    "“Curly quoted line.”",
    "‘Curly single quoted.’",
    "Okay, so here's the cleaned transcript:\n\nFirst thing, the dashboard.",
    "Here is the corrected transcript:\nThe final text.",
    "Cleaned transcript:\nThe final text.",
    "Corrected output:\nThe final text.",
    "Here's the cleaned version:\nThe final text.",
    "Here's the cleaned transcript:\n```\nSo the deploy is done.\n```",
    "Here is the plan:\nship it Friday.",
    "Transcript review notes:\nThe audio was fine.",
    "Corrected items:\n1. The deploy\n2. The tests",
    '"Hello," she said. "Goodbye."',
    "before <b>mid</b> after",
    "",
    "   \n  padded text  \n ",
    "<TRANSCRIPT>Upper tag pair.</TRANSCRIPT>",
    "<transcript>mismatched</other>",
    "```\nfence with `backtick` inside\n```",
    "Here's the cleaned transcript:\n<transcript>\nnested both\n</transcript>",
    "It's a nice day.",
    "Here's the text: inline colon, no newline.",
]

PLAUSIBLE = [
    ("um so basically we should uh probably migrate the the data base",
     "So basically we should probably migrate the database."),
    (" ".join(["word"] * 100), " ".join(["word"] * 30)),
    (" ".join(["word"] * 100), " ".join(["word"] * 40)),
    (" ".join(["word"] * 100), " ".join(["word"] * 39)),
    (" ".join(["word"] * 100), " ".join(["word"] * 128)),
    (" ".join(["word"] * 100), " ".join(["word"] * 129)),
    ("tell me a joke about uh cats",
     "Why did the cat sit on the computer? Because it wanted to keep an eye on "
     "the mouse! Here is another one for you my friend."),
    ("thank you", "You're welcome! Happy to help."),
    ("hello", "Hello! How can I help you today?"),
    ("yes", "Yes, I can certainly do that for you."),
    ("sounds good", "Great! Let me know if you need anything else."),
    ("what time is it", "It is currently three thirty PM for you."),
    ("whats the population of um sweden",
     "Sure, the population of Sweden is about ten million."),
    ("sorry i missed your uh call earlier lets sync tomorrow",
     "Sorry, I missed your call earlier. Let's sync tomorrow."),
    ("um so sorry i missed your uh call earlier lets sync tomorrow",
     "Sorry, I missed your call earlier. Let's sync tomorrow."),
    ("some words here", ""),
    ("um okay sounds good", "Okay, sounds good."),
    ("here is the thing we should ship", "Here is the thing we should ship."),
    ("no problem i can do that", "No problem, I can do that."),
    ("great question everyone", "Great question, everyone."),
    ("tell me a joke about uh cats", "Tell me a joke about cats."),
    ("hello", "Hello."),
    ("one", "one"),
    ("one two three four five", "one two three four five six seven"),
    ("one two three four five", "one two three four five six seven eight"),
    ("um", "Um."),
    ("of course we shipped it", "Of course we shipped it."),
    ("certainly not what i meant", "Certainly not what I meant."),
]

ADDRESSES = [
    "send it to john dot smith at gmail dot com",
    "check wisprit dot dev for the docs",
    "ping me at x@y.com",
    "see https://foo.bar/baz",
    "visit amazon.com now",
    "the quick brown fox jumps",
    "we shipped version two point five",
    "meet me at the coffee shop at noon",
    "go to www.example.org please",
    "email bob at bob dot jones at gmail dot com",
    "the sub dot example dot com host",
    "he lives at number five dot five",
    "call me at three",
    "read docs dot rs later",
    "S-H-A-R-I-Q-U-E at gmail dot com",
]

WORDS = [
    "hello there world",
    "字" * 3000,
    "",
    "   ",
    "word " * 400,
    "a",
    "字" * 5,
    "one two",
]

FIRST_WORD = [
    "um so sorry i missed your call",
    "\"Sure, here's the thing.\"",
    "um uh hmm",
    "",
    "Okay, well, and like so...",
    "Hello there.",
]

print("=== STRIP_WRAPPERS")
for s in WRAPPERS:
    print("        (%s, %s)," % (lit(s), lit(_strip_wrappers(s))))
print("=== PLAUSIBLE")
for raw, ref in PLAUSIBLE:
    print("        (%s, %s, %s)," % (lit(raw), lit(ref), "true" if _plausible(raw, ref) else "false"))
print("=== HAS_ADDRESS")
for s in ADDRESSES:
    print("        (%s, %s)," % (lit(s), "true" if _has_address(s) else "false"))
print("=== ESTIMATED_WORDS")
for s in WORDS:
    label = lit(s) if len(s) < 60 else "REPEAT"
    print("        (%s, %d)," % (label, _estimated_words(s)))
print("=== FIRST_CONTENT_WORD")
for s in FIRST_WORD:
    print("        (%s, %s)," % (lit(s), lit(_first_content_word(s))))

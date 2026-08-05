import random, sys
sys.path.insert(0,'/Users/shariquekhatri/Wisprit')
from wisprit.postprocess import process
class S:
    def __init__(s,**k):
        s._d={"filler_removal":True,"ensure_sentence_period":False,"leading_space":"auto"}; s._d.update(k)
    def get(s,k): return s._d.get(k)
VOCAB = ["um","uh","umm","uhh","uhm","erm","dot","at","new","line","paragraph","period",
         "question","mark","exclamation","point","full","stop","scratch","that","no","wait",
         "com","org","io","dev","me","xyz","gmail","outlook","acme","example","foo","bar",
         "the","a","an","to","of","in","on","and","or","is","was","it","i","for","with",
         "hello","world","sharique","khatri","john","alice","bob","today","tomorrow",
         ",", ".", "!", "?", ";", ":", "\n", "\t", "  ", "don't", "museum", "err", "123"]
random.seed(20260805)
def gen():
    n = random.randint(1, 12)
    toks = [random.choice(VOCAB) for _ in range(n)]
    sep = lambda: random.choice([" "," ","  "," ","\n","\t"])
    return "".join(t + (sep() if i < n-1 else "") for i,t in enumerate(toks))
cases = []
seen = set()
while len(cases) < 400:
    raw = gen()
    if raw in seen: continue
    seen.add(raw)
    cases.append((raw, process(raw, S())))
def swift_str(s):
    out=[]
    for ch in s:
        if ch=="\\": out.append("\\\\")
        elif ch=='"': out.append('\\"')
        elif ch=="\n": out.append("\\n")
        elif ch=="\t": out.append("\\t")
        elif ch=="\r": out.append("\\r")
        elif ord(ch)<0x20: out.append("\\u{%X}"%ord(ch))
        else: out.append(ch)
    return '"'+"".join(out)+'"'
print("// GENERATED — do not hand-edit. Regenerate with:")
print("//   ~/.meetingscribe/venv/bin/python pp_fuzz.py > Tests/WispritPostProcessTests/FuzzGoldens.swift")
print("// 400 pseudo-random token salads (seed 20260805) over the vocabulary every")
print("// stage's regexes react to, each paired with the real Python output. This is")
print("// the differential net for ICU-vs-`re` divergence (\\b, $, backreference")
print("// case folding, greedy backtracking) that the curated fixtures cannot cover.")
print()
print("enum FuzzGoldens {")
print("    static let cases: [(raw: String, expected: String)] = [")
for raw, exp in cases:
    print(f"        ({swift_str(raw)}, {swift_str(exp)}),")
print("    ]")
print("}")

import sys; sys.path.insert(0,'./pylibs')
import jellyfish
from metaphone import doublemetaphone as dm
from rapidfuzz.distance import Levenshtein
def codesim(a,b):
    A,B=dm(a),dm(b); best=0.0
    for x in A:
        for y in B:
            if not x and not y: continue
            best=max(best,1.0-Levenshtein.normalized_distance(x,y))
    return best
def score(a,b):
    jw=jellyfish.jaro_winkler_similarity(a.lower(),b.lower())
    return max(0.6*codesim(a,b)+0.4*jw, 0.9*jw)

DMWORDS = ["Sharique","Shariq","Sharik","Sherrick","Cherie","Cheri","Krzysztof","Caelum","Kaylum",
 "Jon","John","InsForge","Inns Forge","whispered","Wisprit","Siobhan","Shivon","Xiaoli","Shiaowly",
 "Aoife","Eefa","roadmap","tomorrow","today","production","email","migration","ping","parser",
 "Smith","Schmidt","Thompson","Xavier","Jose","San Jacinto","Knight","Wright","Ghislane","Caesar",
 "chianti","McClellan","focaccia","bellocchio","bacchus","accident","succeed","campbell","raspberry",
 "filipowicz","breaux","zhao","school","schermerhorn","resnais","artois","island","carlisle","sugar",
 "dumb","thomas","laugh","hugh","edge","cagney","tagliaro","biaggi","danger","van der wal","Von Neumann",
 "Nguyen","Win","JSON","SHARIQUE","KRZYSZTOF","Wilson","Arnow","Arnoff","Yankelovich","Jankelowicz",
 "gnome","knot","pneumatic","wrack","psycho","cabrillo","gallegos","Michael","Chianti","Bacher",
 "Czerny","Wicz","schooner","Schenker","dgi","judge","bajador","hochmeier","rogier","Andrzej","Zosia",
 "aaa","","x","Y","O'Brien","MacGregor","mac caffrey","dumber","number","thumb","autumn","GH","tough",
 "McLaughlin","gough","ghiradelli","Hugh","Villa","tortilla","Zhang","Zoe","Muzza","Aachen","Bach"]
print("=== DM ===")
for w in DMWORDS:
    p,s = dm(w)
    print(repr(w), "|", p, "|", s)

PAIRS = [("Shariq","Sharique"),("Sharik","Sharique"),("Sherrick","Sharique"),("Caelum","Kaylum"),
 ("Jon","John"),("Inns Forge","InsForge"),("whispered","Wisprit"),("Cherie","Sharique"),
 ("Siobhan","Shivon"),("Xiaoli","Shiaowly"),("Aoife","Eefa"),
 ("roadmap","Sharique"),("tomorrow","Sharique"),("today","Kaylum"),("production","Wisprit"),
 ("email","Sharique"),("Cherie","Krzysztof"),("roadmap","Krzysztof"),("migration","Krzysztof"),
 ("ping","Sharique"),("migration","Sharique"),("hi","Sharique"),("Nguyen","Win"),
 ("parser","JSON"),("fix","JSON"),("need","JSON"),("Cheri","Sharique"),("Shariq","SHARIQUE"),
 ("Cherie","SHARIQUE"),("roadmap","SHARIQUE"),("migration","SHARIQUE"),("ping","SHARIQUE"),
 ("Cherie","KRZYSZTOF"),("roadmap","KRZYSZTOF"),("about","SHARIQUE"),("Correction","SHARIQUE"),
 ("spelled","SHARIQUE"),("actually","SHARIQUE"),("Shariq","JSON"),("release","JSON"),("Wisprit","WISPRIT")]
print("=== SCORE ===")
for a,b in PAIRS:
    print(repr(a),"|",repr(b),"|",repr(round(score(a,b),12)),"|jw",repr(round(jellyfish.jaro_winkler_similarity(a.lower(),b.lower()),12)),"|cs",repr(round(codesim(a,b),12)))

JWPAIRS=[("abcde","abfgh"),("ab","abcdefgh"),("dwayne","duane"),("martha","marhta"),("dixon","dicksonx"),
 ("jellyfish","smellyfish"),("","abc"),("abc",""),("",""),("a","a"),("cherie","sharique"),
 ("krzysztof","cherie"),("sharique","sharique"),("xrk","xr"),("insforge","inns forge")]
print("=== JW ===")
for a,b in JWPAIRS:
    print(repr(a),"|",repr(b),"|",repr(round(jellyfish.jaro_winkler_similarity(a,b),12)))

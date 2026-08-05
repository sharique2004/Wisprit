// GENERATED FIXTURE — do not hand-edit; every value below was produced by
// RUNNING the real Python (~/.meetingscribe/venv/bin/python) over the real term
// data, never by hand. Regenerate with a script that does exactly this:
//
//   from wisprit.bootstrap import _SEED_TERMS          # the 11 seed terms
//   from wisprit.dictionary import Dictionary
//   additions = json.load(open("wisprit-dictionary-additions.json"))   # 126 terms
//   combined  = {"terms": _SEED_TERMS + additions["terms"]}            # 137 total
//   # write combined to a temp dictionary.json with
//   #   json.dumps(combined, indent=2, ensure_ascii=False) + "\n"
//   d = Dictionary(path)
//   terms          = d.terms()
//   correctionPairs = [[p.pattern, r] for p, r in d.corrections()]     # 521 pairs
//   # `cases` = postprocess._apply_dictionary's loop, verbatim:
//   #   for pattern, repl in d.corrections(): text = pattern.sub(repl, text)
//   # `writerSampleOutput` = json.dumps(sample, indent=2, ensure_ascii=False) + "\n"
//
// dictionaryJSON below is the temp file's content minus its trailing newline
// (the raw literal cannot carry it) — tests append "\n" before writing.

enum DictGolden {
    /// The exact dictionary.json the Python side was run against.
    static let dictionaryJSON = #"""
{
  "terms": [
    {
      "term": "Wisprit",
      "hear": [
        "whisper it",
        "wisp rit"
      ]
    },
    {
      "term": "Wispr Flow",
      "hear": [
        "whisper flow",
        "wisper flow"
      ]
    },
    {
      "term": "InsForge",
      "hear": [
        "in forge",
        "ins forge"
      ]
    },
    {
      "term": "MeetingScribe",
      "hear": [
        "meeting scribe"
      ]
    },
    {
      "term": "Claude",
      "hear": [
        "clod"
      ]
    },
    {
      "term": "Anthropic",
      "hear": [
        "and thropic",
        "anthropik"
      ]
    },
    {
      "term": "MLX",
      "hear": [
        "m l x",
        "em el ex"
      ]
    },
    {
      "term": "Sharique",
      "hear": [
        "shariq",
        "sharik",
        "shreek"
      ]
    },
    {
      "term": "Khatri",
      "hear": [
        "katri",
        "kathri"
      ]
    },
    {
      "term": "hackathon",
      "hear": [
        "hacker thought",
        "hacker thoughts",
        "hack a thon",
        "hackerthon",
        "hacker thon"
      ]
    },
    {
      "term": "Penn State",
      "hear": [
        "pen state",
        "penn state university"
      ]
    },
    {
      "term": "Frontrun",
      "hear": [
        "front run",
        "frontron",
        "front runt"
      ]
    },
    {
      "term": "Bibi",
      "hear": [
        "bibby",
        "bebe",
        "b b"
      ]
    },
    {
      "term": "Taazify",
      "hear": [
        "tazify",
        "taseefy",
        "tazzify",
        "ta so fy"
      ]
    },
    {
      "term": "VaultCache",
      "hear": [
        "vault cache",
        "volt cache",
        "vault cash"
      ]
    },
    {
      "term": "Intrsekt",
      "hear": [
        "intersect",
        "intersekt",
        "inter sect"
      ]
    },
    {
      "term": "OmniSch",
      "hear": [
        "omni sch",
        "omni s",
        "omni sketch",
        "omni ess"
      ]
    },
    {
      "term": "Aman UAE",
      "hear": [
        "aman",
        "amman",
        "a man u a e",
        "ahman"
      ]
    },
    {
      "term": "RamAIn",
      "hear": [
        "remain",
        "ram main",
        "ram a in",
        "ram ai n"
      ]
    },
    {
      "term": "OpenSwarm",
      "hear": [
        "open swarm",
        "open swam"
      ]
    },
    {
      "term": "RocketRide",
      "hear": [
        "rocket ride",
        "rocket right"
      ]
    },
    {
      "term": "WellX",
      "hear": [
        "well x",
        "wellex",
        "welex",
        "well ex"
      ]
    },
    {
      "term": "Aarki",
      "hear": [
        "arki",
        "archie",
        "aki",
        "aarchi"
      ]
    },
    {
      "term": "Alnaas Advisory",
      "hear": [
        "al naas advisory",
        "alnas advisory",
        "el naas advisory"
      ]
    },
    {
      "term": "Almosafer",
      "hear": [
        "al musafer",
        "almosafir",
        "al mosafer"
      ]
    },
    {
      "term": "SEERA",
      "hear": [
        "sera",
        "sierra",
        "seera",
        "sarah"
      ]
    },
    {
      "term": "ORIS",
      "hear": [
        "oris",
        "orris",
        "or is",
        "o r i s"
      ]
    },
    {
      "term": "Talabat",
      "hear": [
        "tala bat",
        "telabat",
        "talabot"
      ]
    },
    {
      "term": "Spotnana",
      "hear": [
        "spot nana",
        "spotnara",
        "spot nona"
      ]
    },
    {
      "term": "Avora",
      "hear": [
        "aurora",
        "a vora",
        "avora"
      ]
    },
    {
      "term": "Flow71",
      "hear": [
        "flow 71",
        "flo seventy one",
        "flow seventy one"
      ]
    },
    {
      "term": "Heliux",
      "hear": [
        "helix",
        "helios",
        "heli ux"
      ]
    },
    {
      "term": "Whop",
      "hear": [
        "wop",
        "whopp",
        "hwop"
      ]
    },
    {
      "term": "Bland",
      "hear": [
        "blend",
        "bland ai"
      ]
    },
    {
      "term": "Letta",
      "hear": [
        "letter",
        "leta",
        "letta"
      ]
    },
    {
      "term": "Mercor",
      "hear": [
        "mercore",
        "mer core",
        "mercor"
      ]
    },
    {
      "term": "Mechanize",
      "hear": [
        "mechanized",
        "mechanize"
      ]
    },
    {
      "term": "CloudCruise",
      "hear": [
        "cloud cruise",
        "cloud cruz"
      ]
    },
    {
      "term": "ClimateAi",
      "hear": [
        "climate ai",
        "climate eye"
      ]
    },
    {
      "term": "EliseAI",
      "hear": [
        "elise ai",
        "elise eye",
        "a lease ai"
      ]
    },
    {
      "term": "Eightfold",
      "hear": [
        "eight fold",
        "ate fold"
      ]
    },
    {
      "term": "Capgemini",
      "hear": [
        "cap gemini",
        "capgemeny",
        "cap jemini"
      ]
    },
    {
      "term": "CrowdStrike",
      "hear": [
        "crowd strike",
        "crowd strick"
      ]
    },
    {
      "term": "Nuro",
      "hear": [
        "neuro",
        "new ro",
        "nuro"
      ]
    },
    {
      "term": "Rubrik",
      "hear": [
        "rubric",
        "rubrick",
        "rubrik"
      ]
    },
    {
      "term": "Kyron Medical",
      "hear": [
        "kyron",
        "kiron",
        "chiron",
        "kairon",
        "kyron medical"
      ]
    },
    {
      "term": "SpineSearch",
      "hear": [
        "spine search",
        "spine surge"
      ]
    },
    {
      "term": "Prokatchers",
      "hear": [
        "pro catchers",
        "pro katchers",
        "procatchers",
        "pro cachers"
      ]
    },
    {
      "term": "Baseten",
      "hear": [
        "base ten",
        "basten",
        "baseton"
      ]
    },
    {
      "term": "Thunder Compute",
      "hear": [
        "thunder compute",
        "thunder computer"
      ]
    },
    {
      "term": "Ploy",
      "hear": [
        "play",
        "employ",
        "ploy"
      ]
    },
    {
      "term": "Legion Health",
      "hear": [
        "legion health",
        "region health"
      ]
    },
    {
      "term": "Arkestro",
      "hear": [
        "orchestra",
        "ar kestro",
        "orkestro",
        "arkestro"
      ]
    },
    {
      "term": "Meridian",
      "hear": [
        "meridian",
        "meridien"
      ]
    },
    {
      "term": "Hotel Trader",
      "hear": [
        "hotel trader",
        "hotel traitor"
      ]
    },
    {
      "term": "Polygon Labs",
      "hear": [
        "polygon labs",
        "poly gon labs"
      ]
    },
    {
      "term": "Symbotic",
      "hear": [
        "symbiotic",
        "sim botic",
        "symbotic"
      ]
    },
    {
      "term": "Revolut",
      "hear": [
        "revolt",
        "revaloot",
        "revolute"
      ]
    },
    {
      "term": "Benchling",
      "hear": [
        "bench ling",
        "benchling"
      ]
    },
    {
      "term": "Secureframe",
      "hear": [
        "secure frame",
        "secured frame"
      ]
    },
    {
      "term": "CookUnity",
      "hear": [
        "cook unity",
        "cook you nity"
      ]
    },
    {
      "term": "Scale AI",
      "hear": [
        "scale ai",
        "scale eye"
      ]
    },
    {
      "term": "xAI",
      "hear": [
        "x ai",
        "x a i",
        "ex ai"
      ]
    },
    {
      "term": "Databricks",
      "hear": [
        "data bricks",
        "data brix"
      ]
    },
    {
      "term": "Spotnana",
      "hear": [
        "spot nana",
        "spot nona"
      ]
    },
    {
      "term": "Four Hands",
      "hear": [
        "four hands",
        "for hands"
      ]
    },
    {
      "term": "HPE",
      "hear": [
        "h p e",
        "hpe",
        "h p e e"
      ]
    },
    {
      "term": "T-Mobile",
      "hear": [
        "t mobile",
        "tee mobile"
      ]
    },
    {
      "term": "Sarosh Waghmar",
      "hear": [
        "sarosh wagmar",
        "saroj waghmar",
        "sarosh wag mar"
      ]
    },
    {
      "term": "Mahanth Gowda",
      "hear": [
        "mahant gowda",
        "mahanth gouda",
        "ma hanth gowda"
      ]
    },
    {
      "term": "Aidan Levitz",
      "hear": [
        "aiden levits",
        "aidan levids",
        "aidan levitz"
      ]
    },
    {
      "term": "Sandra Gras",
      "hear": [
        "sandra grass",
        "sandra gras"
      ]
    },
    {
      "term": "Leslie Vu",
      "hear": [
        "leslie voo",
        "leslie vu",
        "leslie view"
      ]
    },
    {
      "term": "Sidney Reich",
      "hear": [
        "sydney rike",
        "sidney rich",
        "sidney reich"
      ]
    },
    {
      "term": "Vipul Gupta",
      "hear": [
        "we pull gupta",
        "bipul gupta",
        "vipul gupta"
      ]
    },
    {
      "term": "D'nika Voges",
      "hear": [
        "danika voges",
        "denika vogues",
        "d nika voges"
      ]
    },
    {
      "term": "Mitul Gandhi",
      "hear": [
        "mittul gandhi",
        "meetul gandhi",
        "mit tul gandhi"
      ]
    },
    {
      "term": "Khushboo Khatri",
      "hear": [
        "kush boo khatri",
        "kushbu khatri",
        "khushboo katri"
      ]
    },
    {
      "term": "Anunaya Joshi",
      "hear": [
        "anu naya joshi",
        "a new naya joshi",
        "anunaya joshi"
      ]
    },
    {
      "term": "Ayesha Mahmood",
      "hear": [
        "aisha mahmood",
        "ayesha mahmoud",
        "aisha mahmoud"
      ]
    },
    {
      "term": "Kanika",
      "hear": [
        "canica",
        "kanica",
        "kanika"
      ]
    },
    {
      "term": "Kartikey",
      "hear": [
        "cartikay",
        "kartike",
        "kar ti kay"
      ]
    },
    {
      "term": "Qais Amori",
      "hear": [
        "kais amori",
        "case amori",
        "qais amori"
      ]
    },
    {
      "term": "Savinay Nagendra",
      "hear": [
        "savin nay nagendra",
        "savinay nagendra",
        "savinay na gendra"
      ]
    },
    {
      "term": "Mukund Srinath",
      "hear": [
        "mukand srinath",
        "mukund sri nath",
        "mukund srinath"
      ]
    },
    {
      "term": "Tabbashum Khan",
      "hear": [
        "tabashum khan",
        "tab a shum khan",
        "tabbashum khan"
      ]
    },
    {
      "term": "Andy Santacroce",
      "hear": [
        "andy santa croce",
        "andy santa cross",
        "andy santacroce"
      ]
    },
    {
      "term": "Ronnie Lau",
      "hear": [
        "ronnie lao",
        "ronnie low",
        "ronnie la"
      ]
    },
    {
      "term": "Swati Dey",
      "hear": [
        "swati day",
        "swathi dey",
        "swati de"
      ]
    },
    {
      "term": "Rahil Patel",
      "hear": [
        "raheel patel",
        "rahil patel",
        "ra heel patel"
      ]
    },
    {
      "term": "Mudit Jain",
      "hear": [
        "moodit jain",
        "mood it jane",
        "mudit jain"
      ]
    },
    {
      "term": "Ian Rowe",
      "hear": [
        "ian roe",
        "ian row",
        "ian rowe"
      ]
    },
    {
      "term": "Shervin",
      "hear": [
        "sherwin",
        "sher vin",
        "shervin"
      ]
    },
    {
      "term": "Agastya",
      "hear": [
        "agasthya",
        "augustya",
        "a gas tya"
      ]
    },
    {
      "term": "Abhishek",
      "hear": [
        "abishek",
        "a bee shek",
        "abhishek"
      ]
    },
    {
      "term": "Yash Patni",
      "hear": [
        "yash putney",
        "yash patni",
        "yash pat ni"
      ]
    },
    {
      "term": "Vansh Ramani",
      "hear": [
        "vaunsh ramani",
        "vansh ramani",
        "vaan ramani"
      ]
    },
    {
      "term": "Sanjeev Suresh",
      "hear": [
        "san jeev suresh",
        "sanjiv suresh",
        "sanjeev suresh"
      ]
    },
    {
      "term": "Mostafa Esmaiel",
      "hear": [
        "mustafa esmail",
        "mostafa esmaiel",
        "mustafa ismail"
      ]
    },
    {
      "term": "RAG",
      "hear": [
        "rag",
        "rack",
        "r a g"
      ]
    },
    {
      "term": "LLM",
      "hear": [
        "l l m",
        "elelem",
        "l lm"
      ]
    },
    {
      "term": "FastAPI",
      "hear": [
        "fast api",
        "fast a p i",
        "fastapi"
      ]
    },
    {
      "term": "Next.js",
      "hear": [
        "next js",
        "next j s",
        "nextjs"
      ]
    },
    {
      "term": "PostgreSQL",
      "hear": [
        "postgresql",
        "postgres",
        "post gre sql"
      ]
    },
    {
      "term": "SwiftUI",
      "hear": [
        "swift ui",
        "swift u i",
        "swiftui"
      ]
    },
    {
      "term": "MCP",
      "hear": [
        "m c p",
        "mcp",
        "em cee pee"
      ]
    },
    {
      "term": "CoderPad",
      "hear": [
        "coder pad",
        "coder pod",
        "coda pad"
      ]
    },
    {
      "term": "EventKit",
      "hear": [
        "event kit",
        "event kid"
      ]
    },
    {
      "term": "CoreAudio",
      "hear": [
        "core audio",
        "core oddio"
      ]
    },
    {
      "term": "mlx-whisper",
      "hear": [
        "mlx whisper",
        "m l x whisper"
      ]
    },
    {
      "term": "faster-whisper",
      "hear": [
        "faster whisper",
        "faster whisperer"
      ]
    },
    {
      "term": "speechbrain",
      "hear": [
        "speech brain",
        "speech train"
      ]
    },
    {
      "term": "ECAPA",
      "hear": [
        "e capa",
        "ecopa",
        "e c a p a"
      ]
    },
    {
      "term": "Ollama",
      "hear": [
        "olama",
        "oh lama",
        "o llama"
      ]
    },
    {
      "term": "Qwen",
      "hear": [
        "quinn",
        "q wen",
        "queen",
        "kwen"
      ]
    },
    {
      "term": "Ragas",
      "hear": [
        "ragas",
        "raghas",
        "rag as",
        "ra gas"
      ]
    },
    {
      "term": "PBKDF2",
      "hear": [
        "p b k d f 2",
        "pbkdf two",
        "pb kdf 2"
      ]
    },
    {
      "term": "AES-256",
      "hear": [
        "a e s 256",
        "aes two fifty six",
        " a e s two five six"
      ]
    },
    {
      "term": "LangChain",
      "hear": [
        "lang chain",
        "long chain",
        "line chain"
      ]
    },
    {
      "term": "FAISS",
      "hear": [
        "face",
        "fhighs",
        "f a i s s",
        "faiss"
      ]
    },
    {
      "term": "Pinecone",
      "hear": [
        "pine cone",
        "pine phone"
      ]
    },
    {
      "term": "Chroma",
      "hear": [
        "chroma",
        "chrome a",
        "kroma"
      ]
    },
    {
      "term": "Vercel",
      "hear": [
        "ver cell",
        "versell",
        "vor sell"
      ]
    },
    {
      "term": "shadcn",
      "hear": [
        "shad cn",
        "shad c n",
        "shatzen"
      ]
    },
    {
      "term": "BACnet",
      "hear": [
        "back net",
        "bacnet",
        "bak net"
      ]
    },
    {
      "term": "Verilog",
      "hear": [
        "verilog",
        "very log",
        "vera log"
      ]
    },
    {
      "term": "arXiv",
      "hear": [
        "archive",
        "ar xiv",
        "ar chive"
      ]
    },
    {
      "term": "ECCV",
      "hear": [
        "e c c v",
        "eccv",
        "e triple c v"
      ]
    },
    {
      "term": "EDGAR",
      "hear": [
        "edgar",
        "ed gar"
      ]
    },
    {
      "term": "STEM OPT",
      "hear": [
        "stem opt",
        "stem o p t",
        "stem opti"
      ]
    },
    {
      "term": "EAD",
      "hear": [
        "e a d",
        "ead",
        "e ad"
      ]
    },
    {
      "term": "H-1B",
      "hear": [
        "h one b",
        "h 1 b",
        "age one b"
      ]
    },
    {
      "term": "Cal.com",
      "hear": [
        "cal com",
        "cal dot com"
      ]
    },
    {
      "term": "Resend",
      "hear": [
        "resend",
        "re send"
      ]
    },
    {
      "term": "De Anza",
      "hear": [
        "de anza",
        "the anza",
        "de onza"
      ]
    },
    {
      "term": "Cupertino",
      "hear": [
        "cupertino",
        "cooper tino"
      ]
    },
    {
      "term": "LeetCode",
      "hear": [
        "leet code",
        "lead code",
        "leetcode"
      ]
    }
  ]
}
"""#

    /// terms / correctionPairs / cases / writerSampleOutput, as JSON.
    static let goldensJSON = #"""
{
 "terms": [
  "Wisprit",
  "Wispr Flow",
  "InsForge",
  "MeetingScribe",
  "Claude",
  "Anthropic",
  "MLX",
  "Sharique",
  "Khatri",
  "hackathon",
  "Penn State",
  "Frontrun",
  "Bibi",
  "Taazify",
  "VaultCache",
  "Intrsekt",
  "OmniSch",
  "Aman UAE",
  "RamAIn",
  "OpenSwarm",
  "RocketRide",
  "WellX",
  "Aarki",
  "Alnaas Advisory",
  "Almosafer",
  "SEERA",
  "ORIS",
  "Talabat",
  "Spotnana",
  "Avora",
  "Flow71",
  "Heliux",
  "Whop",
  "Bland",
  "Letta",
  "Mercor",
  "Mechanize",
  "CloudCruise",
  "ClimateAi",
  "EliseAI",
  "Eightfold",
  "Capgemini",
  "CrowdStrike",
  "Nuro",
  "Rubrik",
  "Kyron Medical",
  "SpineSearch",
  "Prokatchers",
  "Baseten",
  "Thunder Compute",
  "Ploy",
  "Legion Health",
  "Arkestro",
  "Meridian",
  "Hotel Trader",
  "Polygon Labs",
  "Symbotic",
  "Revolut",
  "Benchling",
  "Secureframe",
  "CookUnity",
  "Scale AI",
  "xAI",
  "Databricks",
  "Spotnana",
  "Four Hands",
  "HPE",
  "T-Mobile",
  "Sarosh Waghmar",
  "Mahanth Gowda",
  "Aidan Levitz",
  "Sandra Gras",
  "Leslie Vu",
  "Sidney Reich",
  "Vipul Gupta",
  "D'nika Voges",
  "Mitul Gandhi",
  "Khushboo Khatri",
  "Anunaya Joshi",
  "Ayesha Mahmood",
  "Kanika",
  "Kartikey",
  "Qais Amori",
  "Savinay Nagendra",
  "Mukund Srinath",
  "Tabbashum Khan",
  "Andy Santacroce",
  "Ronnie Lau",
  "Swati Dey",
  "Rahil Patel",
  "Mudit Jain",
  "Ian Rowe",
  "Shervin",
  "Agastya",
  "Abhishek",
  "Yash Patni",
  "Vansh Ramani",
  "Sanjeev Suresh",
  "Mostafa Esmaiel",
  "RAG",
  "LLM",
  "FastAPI",
  "Next.js",
  "PostgreSQL",
  "SwiftUI",
  "MCP",
  "CoderPad",
  "EventKit",
  "CoreAudio",
  "mlx-whisper",
  "faster-whisper",
  "speechbrain",
  "ECAPA",
  "Ollama",
  "Qwen",
  "Ragas",
  "PBKDF2",
  "AES-256",
  "LangChain",
  "FAISS",
  "Pinecone",
  "Chroma",
  "Vercel",
  "shadcn",
  "BACnet",
  "Verilog",
  "arXiv",
  "ECCV",
  "EDGAR",
  "STEM OPT",
  "EAD",
  "H-1B",
  "Cal.com",
  "Resend",
  "De Anza",
  "Cupertino",
  "LeetCode"
 ],
 "correctionPairs": [
  [
   "\\bpenn\\s+state\\s+university\\b",
   "Penn State"
  ],
  [
   "\\bsavin\\s+nay\\s+nagendra\\b",
   "Savinay Nagendra"
  ],
  [
   "\\ba\\s+e\\s+s\\s+two\\s+five\\s+six\\b",
   "AES-256"
  ],
  [
   "\\bsavinay\\s+na\\s+gendra\\b",
   "Savinay Nagendra"
  ],
  [
   "\\baes\\s+two\\s+fifty\\s+six\\b",
   "AES-256"
  ],
  [
   "\\bal\\s+naas\\s+advisory\\b",
   "Alnaas Advisory"
  ],
  [
   "\\bel\\s+naas\\s+advisory\\b",
   "Alnaas Advisory"
  ],
  [
   "\\bflow\\s+seventy\\s+one\\b",
   "Flow71"
  ],
  [
   "\\bthunder\\s+computer\\b",
   "Thunder Compute"
  ],
  [
   "\\ba\\s+new\\s+naya\\s+joshi\\b",
   "Anunaya Joshi"
  ],
  [
   "\\bSavinay\\s+Nagendra\\b",
   "Savinay Nagendra"
  ],
  [
   "\\bsavinay\\s+nagendra\\b",
   "Savinay Nagendra"
  ],
  [
   "\\bandy\\s+santa\\s+croce\\b",
   "Andy Santacroce"
  ],
  [
   "\\bandy\\s+santa\\s+cross\\b",
   "Andy Santacroce"
  ],
  [
   "\\bfaster\\s+whisperer\\b",
   "faster-whisper"
  ],
  [
   "\\bhacker\\s+thoughts\\b",
   "hackathon"
  ],
  [
   "\\bAlnaas\\s+Advisory\\b",
   "Alnaas Advisory"
  ],
  [
   "\\bflo\\s+seventy\\s+one\\b",
   "Flow71"
  ],
  [
   "\\bThunder\\s+Compute\\b",
   "Thunder Compute"
  ],
  [
   "\\bthunder\\s+compute\\b",
   "Thunder Compute"
  ],
  [
   "\\bKhushboo\\s+Khatri\\b",
   "Khushboo Khatri"
  ],
  [
   "\\bkush\\s+boo\\s+khatri\\b",
   "Khushboo Khatri"
  ],
  [
   "\\bmukund\\s+sri\\s+nath\\b",
   "Mukund Srinath"
  ],
  [
   "\\btab\\s+a\\s+shum\\s+khan\\b",
   "Tabbashum Khan"
  ],
  [
   "\\bAndy\\s+Santacroce\\b",
   "Andy Santacroce"
  ],
  [
   "\\bandy\\s+santacroce\\b",
   "Andy Santacroce"
  ],
  [
   "\\bsan\\s+jeev\\s+suresh\\b",
   "Sanjeev Suresh"
  ],
  [
   "\\bMostafa\\s+Esmaiel\\b",
   "Mostafa Esmaiel"
  ],
  [
   "\\bmostafa\\s+esmaiel\\b",
   "Mostafa Esmaiel"
  ],
  [
   "\\bmeeting\\s+scribe\\b",
   "MeetingScribe"
  ],
  [
   "\\bhacker\\s+thought\\b",
   "hackathon"
  ],
  [
   "\\balnas\\s+advisory\\b",
   "Alnaas Advisory"
  ],
  [
   "\\bSarosh\\s+Waghmar\\b",
   "Sarosh Waghmar"
  ],
  [
   "\\bsarosh\\s+wag\\s+mar\\b",
   "Sarosh Waghmar"
  ],
  [
   "\\bma\\s+hanth\\s+gowda\\b",
   "Mahanth Gowda"
  ],
  [
   "\\bmit\\s+tul\\s+gandhi\\b",
   "Mitul Gandhi"
  ],
  [
   "\\bkhushboo\\s+katri\\b",
   "Khushboo Khatri"
  ],
  [
   "\\banu\\s+naya\\s+joshi\\b",
   "Anunaya Joshi"
  ],
  [
   "\\bAyesha\\s+Mahmood\\b",
   "Ayesha Mahmood"
  ],
  [
   "\\bayesha\\s+mahmoud\\b",
   "Ayesha Mahmood"
  ],
  [
   "\\bMukund\\s+Srinath\\b",
   "Mukund Srinath"
  ],
  [
   "\\bmukand\\s+srinath\\b",
   "Mukund Srinath"
  ],
  [
   "\\bmukund\\s+srinath\\b",
   "Mukund Srinath"
  ],
  [
   "\\bTabbashum\\s+Khan\\b",
   "Tabbashum Khan"
  ],
  [
   "\\btabbashum\\s+khan\\b",
   "Tabbashum Khan"
  ],
  [
   "\\bSanjeev\\s+Suresh\\b",
   "Sanjeev Suresh"
  ],
  [
   "\\bsanjeev\\s+suresh\\b",
   "Sanjeev Suresh"
  ],
  [
   "\\bmustafa\\s+esmail\\b",
   "Mostafa Esmaiel"
  ],
  [
   "\\bmustafa\\s+ismail\\b",
   "Mostafa Esmaiel"
  ],
  [
   "\\bfaster\\-whisper\\b",
   "faster-whisper"
  ],
  [
   "\\bfaster\\s+whisper\\b",
   "faster-whisper"
  ],
  [
   "\\bMeetingScribe\\b",
   "MeetingScribe"
  ],
  [
   "\\bKyron\\s+Medical\\b",
   "Kyron Medical"
  ],
  [
   "\\bkyron\\s+medical\\b",
   "Kyron Medical"
  ],
  [
   "\\bLegion\\s+Health\\b",
   "Legion Health"
  ],
  [
   "\\blegion\\s+health\\b",
   "Legion Health"
  ],
  [
   "\\bregion\\s+health\\b",
   "Legion Health"
  ],
  [
   "\\bhotel\\s+traitor\\b",
   "Hotel Trader"
  ],
  [
   "\\bpoly\\s+gon\\s+labs\\b",
   "Polygon Labs"
  ],
  [
   "\\bsecured\\s+frame\\b",
   "Secureframe"
  ],
  [
   "\\bcook\\s+you\\s+nity\\b",
   "CookUnity"
  ],
  [
   "\\bsarosh\\s+wagmar\\b",
   "Sarosh Waghmar"
  ],
  [
   "\\bsaroj\\s+waghmar\\b",
   "Sarosh Waghmar"
  ],
  [
   "\\bMahanth\\s+Gowda\\b",
   "Mahanth Gowda"
  ],
  [
   "\\bmahanth\\s+gouda\\b",
   "Mahanth Gowda"
  ],
  [
   "\\bwe\\s+pull\\s+gupta\\b",
   "Vipul Gupta"
  ],
  [
   "\\bdenika\\s+vogues\\b",
   "D'nika Voges"
  ],
  [
   "\\bmittul\\s+gandhi\\b",
   "Mitul Gandhi"
  ],
  [
   "\\bmeetul\\s+gandhi\\b",
   "Mitul Gandhi"
  ],
  [
   "\\bkushbu\\s+khatri\\b",
   "Khushboo Khatri"
  ],
  [
   "\\bAnunaya\\s+Joshi\\b",
   "Anunaya Joshi"
  ],
  [
   "\\banunaya\\s+joshi\\b",
   "Anunaya Joshi"
  ],
  [
   "\\baisha\\s+mahmood\\b",
   "Ayesha Mahmood"
  ],
  [
   "\\baisha\\s+mahmoud\\b",
   "Ayesha Mahmood"
  ],
  [
   "\\btabashum\\s+khan\\b",
   "Tabbashum Khan"
  ],
  [
   "\\bra\\s+heel\\s+patel\\b",
   "Rahil Patel"
  ],
  [
   "\\bvaunsh\\s+ramani\\b",
   "Vansh Ramani"
  ],
  [
   "\\bsanjiv\\s+suresh\\b",
   "Sanjeev Suresh"
  ],
  [
   "\\bm\\s+l\\s+x\\s+whisper\\b",
   "mlx-whisper"
  ],
  [
   "\\bwhisper\\s+flow\\b",
   "Wispr Flow"
  ],
  [
   "\\brocket\\s+right\\b",
   "RocketRide"
  ],
  [
   "\\bcloud\\s+cruise\\b",
   "CloudCruise"
  ],
  [
   "\\bcrowd\\s+strike\\b",
   "CrowdStrike"
  ],
  [
   "\\bcrowd\\s+strick\\b",
   "CrowdStrike"
  ],
  [
   "\\bspine\\s+search\\b",
   "SpineSearch"
  ],
  [
   "\\bpro\\s+catchers\\b",
   "Prokatchers"
  ],
  [
   "\\bpro\\s+katchers\\b",
   "Prokatchers"
  ],
  [
   "\\bHotel\\s+Trader\\b",
   "Hotel Trader"
  ],
  [
   "\\bhotel\\s+trader\\b",
   "Hotel Trader"
  ],
  [
   "\\bPolygon\\s+Labs\\b",
   "Polygon Labs"
  ],
  [
   "\\bpolygon\\s+labs\\b",
   "Polygon Labs"
  ],
  [
   "\\bsecure\\s+frame\\b",
   "Secureframe"
  ],
  [
   "\\bmahant\\s+gowda\\b",
   "Mahanth Gowda"
  ],
  [
   "\\bAidan\\s+Levitz\\b",
   "Aidan Levitz"
  ],
  [
   "\\baiden\\s+levits\\b",
   "Aidan Levitz"
  ],
  [
   "\\baidan\\s+levids\\b",
   "Aidan Levitz"
  ],
  [
   "\\baidan\\s+levitz\\b",
   "Aidan Levitz"
  ],
  [
   "\\bsandra\\s+grass\\b",
   "Sandra Gras"
  ],
  [
   "\\bSidney\\s+Reich\\b",
   "Sidney Reich"
  ],
  [
   "\\bsidney\\s+reich\\b",
   "Sidney Reich"
  ],
  [
   "\\bD'nika\\s+Voges\\b",
   "D'nika Voges"
  ],
  [
   "\\bdanika\\s+voges\\b",
   "D'nika Voges"
  ],
  [
   "\\bd\\s+nika\\s+voges\\b",
   "D'nika Voges"
  ],
  [
   "\\bMitul\\s+Gandhi\\b",
   "Mitul Gandhi"
  ],
  [
   "\\braheel\\s+patel\\b",
   "Rahil Patel"
  ],
  [
   "\\bmood\\s+it\\s+jane\\b",
   "Mudit Jain"
  ],
  [
   "\\bVansh\\s+Ramani\\b",
   "Vansh Ramani"
  ],
  [
   "\\bvansh\\s+ramani\\b",
   "Vansh Ramani"
  ],
  [
   "\\bpost\\s+gre\\s+sql\\b",
   "PostgreSQL"
  ],
  [
   "\\bspeech\\s+brain\\b",
   "speechbrain"
  ],
  [
   "\\bspeech\\s+train\\b",
   "speechbrain"
  ],
  [
   "\\be\\s+triple\\s+c\\s+v\\b",
   "ECCV"
  ],
  [
   "\\bwisper\\s+flow\\b",
   "Wispr Flow"
  ],
  [
   "\\band\\s+thropic\\b",
   "Anthropic"
  ],
  [
   "\\bhack\\s+a\\s+thon\\b",
   "hackathon"
  ],
  [
   "\\bhacker\\s+thon\\b",
   "hackathon"
  ],
  [
   "\\bvault\\s+cache\\b",
   "VaultCache"
  ],
  [
   "\\bomni\\s+sketch\\b",
   "OmniSch"
  ],
  [
   "\\ba\\s+man\\s+u\\s+a\\s+e\\b",
   "Aman UAE"
  ],
  [
   "\\brocket\\s+ride\\b",
   "RocketRide"
  ],
  [
   "\\bCloudCruise\\b",
   "CloudCruise"
  ],
  [
   "\\bclimate\\s+eye\\b",
   "ClimateAi"
  ],
  [
   "\\bCrowdStrike\\b",
   "CrowdStrike"
  ],
  [
   "\\bSpineSearch\\b",
   "SpineSearch"
  ],
  [
   "\\bspine\\s+surge\\b",
   "SpineSearch"
  ],
  [
   "\\bProkatchers\\b",
   "Prokatchers"
  ],
  [
   "\\bprocatchers\\b",
   "Prokatchers"
  ],
  [
   "\\bpro\\s+cachers\\b",
   "Prokatchers"
  ],
  [
   "\\bSecureframe\\b",
   "Secureframe"
  ],
  [
   "\\bdata\\s+bricks\\b",
   "Databricks"
  ],
  [
   "\\bSandra\\s+Gras\\b",
   "Sandra Gras"
  ],
  [
   "\\bsandra\\s+gras\\b",
   "Sandra Gras"
  ],
  [
   "\\bleslie\\s+view\\b",
   "Leslie Vu"
  ],
  [
   "\\bsydney\\s+rike\\b",
   "Sidney Reich"
  ],
  [
   "\\bsidney\\s+rich\\b",
   "Sidney Reich"
  ],
  [
   "\\bVipul\\s+Gupta\\b",
   "Vipul Gupta"
  ],
  [
   "\\bbipul\\s+gupta\\b",
   "Vipul Gupta"
  ],
  [
   "\\bvipul\\s+gupta\\b",
   "Vipul Gupta"
  ],
  [
   "\\bRahil\\s+Patel\\b",
   "Rahil Patel"
  ],
  [
   "\\brahil\\s+patel\\b",
   "Rahil Patel"
  ],
  [
   "\\bmoodit\\s+jain\\b",
   "Mudit Jain"
  ],
  [
   "\\byash\\s+putney\\b",
   "Yash Patni"
  ],
  [
   "\\byash\\s+pat\\s+ni\\b",
   "Yash Patni"
  ],
  [
   "\\bvaan\\s+ramani\\b",
   "Vansh Ramani"
  ],
  [
   "\\bmlx\\-whisper\\b",
   "mlx-whisper"
  ],
  [
   "\\bmlx\\s+whisper\\b",
   "mlx-whisper"
  ],
  [
   "\\bspeechbrain\\b",
   "speechbrain"
  ],
  [
   "\\bp\\s+b\\s+k\\s+d\\s+f\\s+2\\b",
   "PBKDF2"
  ],
  [
   "\\bcal\\s+dot\\s+com\\b",
   "Cal.com"
  ],
  [
   "\\bcooper\\s+tino\\b",
   "Cupertino"
  ],
  [
   "\\bwhisper\\s+it\\b",
   "Wisprit"
  ],
  [
   "\\bWispr\\s+Flow\\b",
   "Wispr Flow"
  ],
  [
   "\\bhackerthon\\b",
   "hackathon"
  ],
  [
   "\\bPenn\\s+State\\b",
   "Penn State"
  ],
  [
   "\\bfront\\s+runt\\b",
   "Frontrun"
  ],
  [
   "\\bVaultCache\\b",
   "VaultCache"
  ],
  [
   "\\bvolt\\s+cache\\b",
   "VaultCache"
  ],
  [
   "\\bvault\\s+cash\\b",
   "VaultCache"
  ],
  [
   "\\binter\\s+sect\\b",
   "Intrsekt"
  ],
  [
   "\\bopen\\s+swarm\\b",
   "OpenSwarm"
  ],
  [
   "\\bRocketRide\\b",
   "RocketRide"
  ],
  [
   "\\bal\\s+musafer\\b",
   "Almosafer"
  ],
  [
   "\\bal\\s+mosafer\\b",
   "Almosafer"
  ],
  [
   "\\bmechanized\\b",
   "Mechanize"
  ],
  [
   "\\bcloud\\s+cruz\\b",
   "CloudCruise"
  ],
  [
   "\\bclimate\\s+ai\\b",
   "ClimateAi"
  ],
  [
   "\\ba\\s+lease\\s+ai\\b",
   "EliseAI"
  ],
  [
   "\\beight\\s+fold\\b",
   "Eightfold"
  ],
  [
   "\\bcap\\s+gemini\\b",
   "Capgemini"
  ],
  [
   "\\bcap\\s+jemini\\b",
   "Capgemini"
  ],
  [
   "\\bbench\\s+ling\\b",
   "Benchling"
  ],
  [
   "\\bcook\\s+unity\\b",
   "CookUnity"
  ],
  [
   "\\bDatabricks\\b",
   "Databricks"
  ],
  [
   "\\bFour\\s+Hands\\b",
   "Four Hands"
  ],
  [
   "\\bfour\\s+hands\\b",
   "Four Hands"
  ],
  [
   "\\btee\\s+mobile\\b",
   "T-Mobile"
  ],
  [
   "\\bleslie\\s+voo\\b",
   "Leslie Vu"
  ],
  [
   "\\bkar\\s+ti\\s+kay\\b",
   "Kartikey"
  ],
  [
   "\\bQais\\s+Amori\\b",
   "Qais Amori"
  ],
  [
   "\\bkais\\s+amori\\b",
   "Qais Amori"
  ],
  [
   "\\bcase\\s+amori\\b",
   "Qais Amori"
  ],
  [
   "\\bqais\\s+amori\\b",
   "Qais Amori"
  ],
  [
   "\\bRonnie\\s+Lau\\b",
   "Ronnie Lau"
  ],
  [
   "\\bronnie\\s+lao\\b",
   "Ronnie Lau"
  ],
  [
   "\\bronnie\\s+low\\b",
   "Ronnie Lau"
  ],
  [
   "\\bswathi\\s+dey\\b",
   "Swati Dey"
  ],
  [
   "\\bMudit\\s+Jain\\b",
   "Mudit Jain"
  ],
  [
   "\\bmudit\\s+jain\\b",
   "Mudit Jain"
  ],
  [
   "\\ba\\s+bee\\s+shek\\b",
   "Abhishek"
  ],
  [
   "\\bYash\\s+Patni\\b",
   "Yash Patni"
  ],
  [
   "\\byash\\s+patni\\b",
   "Yash Patni"
  ],
  [
   "\\bfast\\s+a\\s+p\\s+i\\b",
   "FastAPI"
  ],
  [
   "\\bPostgreSQL\\b",
   "PostgreSQL"
  ],
  [
   "\\bpostgresql\\b",
   "PostgreSQL"
  ],
  [
   "\\bem\\s+cee\\s+pee\\b",
   "MCP"
  ],
  [
   "\\bcore\\s+audio\\b",
   "CoreAudio"
  ],
  [
   "\\bcore\\s+oddio\\b",
   "CoreAudio"
  ],
  [
   "\\blang\\s+chain\\b",
   "LangChain"
  ],
  [
   "\\blong\\s+chain\\b",
   "LangChain"
  ],
  [
   "\\bline\\s+chain\\b",
   "LangChain"
  ],
  [
   "\\bpine\\s+phone\\b",
   "Pinecone"
  ],
  [
   "\\bstem\\s+o\\s+p\\s+t\\b",
   "STEM OPT"
  ],
  [
   "\\bins\\s+forge\\b",
   "InsForge"
  ],
  [
   "\\bAnthropic\\b",
   "Anthropic"
  ],
  [
   "\\banthropik\\b",
   "Anthropic"
  ],
  [
   "\\bhackathon\\b",
   "hackathon"
  ],
  [
   "\\bpen\\s+state\\b",
   "Penn State"
  ],
  [
   "\\bfront\\s+run\\b",
   "Frontrun"
  ],
  [
   "\\bintersect\\b",
   "Intrsekt"
  ],
  [
   "\\bintersekt\\b",
   "Intrsekt"
  ],
  [
   "\\bOpenSwarm\\b",
   "OpenSwarm"
  ],
  [
   "\\bopen\\s+swam\\b",
   "OpenSwarm"
  ],
  [
   "\\bAlmosafer\\b",
   "Almosafer"
  ],
  [
   "\\balmosafir\\b",
   "Almosafer"
  ],
  [
   "\\bspot\\s+nana\\b",
   "Spotnana"
  ],
  [
   "\\bspot\\s+nona\\b",
   "Spotnana"
  ],
  [
   "\\bMechanize\\b",
   "Mechanize"
  ],
  [
   "\\bmechanize\\b",
   "Mechanize"
  ],
  [
   "\\bClimateAi\\b",
   "ClimateAi"
  ],
  [
   "\\belise\\s+eye\\b",
   "EliseAI"
  ],
  [
   "\\bEightfold\\b",
   "Eightfold"
  ],
  [
   "\\bCapgemini\\b",
   "Capgemini"
  ],
  [
   "\\bcapgemeny\\b",
   "Capgemini"
  ],
  [
   "\\borchestra\\b",
   "Arkestro"
  ],
  [
   "\\bar\\s+kestro\\b",
   "Arkestro"
  ],
  [
   "\\bsymbiotic\\b",
   "Symbotic"
  ],
  [
   "\\bsim\\s+botic\\b",
   "Symbotic"
  ],
  [
   "\\bBenchling\\b",
   "Benchling"
  ],
  [
   "\\bbenchling\\b",
   "Benchling"
  ],
  [
   "\\bCookUnity\\b",
   "CookUnity"
  ],
  [
   "\\bscale\\s+eye\\b",
   "Scale AI"
  ],
  [
   "\\bdata\\s+brix\\b",
   "Databricks"
  ],
  [
   "\\bspot\\s+nana\\b",
   "Spotnana"
  ],
  [
   "\\bspot\\s+nona\\b",
   "Spotnana"
  ],
  [
   "\\bfor\\s+hands\\b",
   "Four Hands"
  ],
  [
   "\\bLeslie\\s+Vu\\b",
   "Leslie Vu"
  ],
  [
   "\\bleslie\\s+vu\\b",
   "Leslie Vu"
  ],
  [
   "\\bronnie\\s+la\\b",
   "Ronnie Lau"
  ],
  [
   "\\bSwati\\s+Dey\\b",
   "Swati Dey"
  ],
  [
   "\\bswati\\s+day\\b",
   "Swati Dey"
  ],
  [
   "\\ba\\s+gas\\s+tya\\b",
   "Agastya"
  ],
  [
   "\\bswift\\s+u\\s+i\\b",
   "SwiftUI"
  ],
  [
   "\\bcoder\\s+pad\\b",
   "CoderPad"
  ],
  [
   "\\bcoder\\s+pod\\b",
   "CoderPad"
  ],
  [
   "\\bevent\\s+kit\\b",
   "EventKit"
  ],
  [
   "\\bevent\\s+kid\\b",
   "EventKit"
  ],
  [
   "\\bCoreAudio\\b",
   "CoreAudio"
  ],
  [
   "\\be\\s+c\\s+a\\s+p\\s+a\\b",
   "ECAPA"
  ],
  [
   "\\bpbkdf\\s+two\\b",
   "PBKDF2"
  ],
  [
   "\\ba\\s+e\\s+s\\s+256\\b",
   "AES-256"
  ],
  [
   "\\bLangChain\\b",
   "LangChain"
  ],
  [
   "\\bf\\s+a\\s+i\\s+s\\s+s\\b",
   "FAISS"
  ],
  [
   "\\bpine\\s+cone\\b",
   "Pinecone"
  ],
  [
   "\\bstem\\s+opti\\b",
   "STEM OPT"
  ],
  [
   "\\bage\\s+one\\s+b\\b",
   "H-1B"
  ],
  [
   "\\bCupertino\\b",
   "Cupertino"
  ],
  [
   "\\bcupertino\\b",
   "Cupertino"
  ],
  [
   "\\bleet\\s+code\\b",
   "LeetCode"
  ],
  [
   "\\blead\\s+code\\b",
   "LeetCode"
  ],
  [
   "\\bwisp\\s+rit\\b",
   "Wisprit"
  ],
  [
   "\\bInsForge\\b",
   "InsForge"
  ],
  [
   "\\bin\\s+forge\\b",
   "InsForge"
  ],
  [
   "\\bem\\s+el\\s+ex\\b",
   "MLX"
  ],
  [
   "\\bSharique\\b",
   "Sharique"
  ],
  [
   "\\bFrontrun\\b",
   "Frontrun"
  ],
  [
   "\\bfrontron\\b",
   "Frontrun"
  ],
  [
   "\\bta\\s+so\\s+fy\\b",
   "Taazify"
  ],
  [
   "\\bIntrsekt\\b",
   "Intrsekt"
  ],
  [
   "\\bomni\\s+sch\\b",
   "OmniSch"
  ],
  [
   "\\bomni\\s+ess\\b",
   "OmniSch"
  ],
  [
   "\\bAman\\s+UAE\\b",
   "Aman UAE"
  ],
  [
   "\\bram\\s+main\\b",
   "RamAIn"
  ],
  [
   "\\bram\\s+a\\s+in\\b",
   "RamAIn"
  ],
  [
   "\\bram\\s+ai\\s+n\\b",
   "RamAIn"
  ],
  [
   "\\btala\\s+bat\\b",
   "Talabat"
  ],
  [
   "\\bSpotnana\\b",
   "Spotnana"
  ],
  [
   "\\bspotnara\\b",
   "Spotnana"
  ],
  [
   "\\bbland\\s+ai\\b",
   "Bland"
  ],
  [
   "\\bmer\\s+core\\b",
   "Mercor"
  ],
  [
   "\\belise\\s+ai\\b",
   "EliseAI"
  ],
  [
   "\\bate\\s+fold\\b",
   "Eightfold"
  ],
  [
   "\\bbase\\s+ten\\b",
   "Baseten"
  ],
  [
   "\\bArkestro\\b",
   "Arkestro"
  ],
  [
   "\\borkestro\\b",
   "Arkestro"
  ],
  [
   "\\barkestro\\b",
   "Arkestro"
  ],
  [
   "\\bMeridian\\b",
   "Meridian"
  ],
  [
   "\\bmeridian\\b",
   "Meridian"
  ],
  [
   "\\bmeridien\\b",
   "Meridian"
  ],
  [
   "\\bSymbotic\\b",
   "Symbotic"
  ],
  [
   "\\bsymbotic\\b",
   "Symbotic"
  ],
  [
   "\\brevaloot\\b",
   "Revolut"
  ],
  [
   "\\brevolute\\b",
   "Revolut"
  ],
  [
   "\\bScale\\s+AI\\b",
   "Scale AI"
  ],
  [
   "\\bscale\\s+ai\\b",
   "Scale AI"
  ],
  [
   "\\bSpotnana\\b",
   "Spotnana"
  ],
  [
   "\\bT\\-Mobile\\b",
   "T-Mobile"
  ],
  [
   "\\bt\\s+mobile\\b",
   "T-Mobile"
  ],
  [
   "\\bKartikey\\b",
   "Kartikey"
  ],
  [
   "\\bcartikay\\b",
   "Kartikey"
  ],
  [
   "\\bswati\\s+de\\b",
   "Swati Dey"
  ],
  [
   "\\bIan\\s+Rowe\\b",
   "Ian Rowe"
  ],
  [
   "\\bian\\s+rowe\\b",
   "Ian Rowe"
  ],
  [
   "\\bsher\\s+vin\\b",
   "Shervin"
  ],
  [
   "\\bagasthya\\b",
   "Agastya"
  ],
  [
   "\\baugustya\\b",
   "Agastya"
  ],
  [
   "\\bAbhishek\\b",
   "Abhishek"
  ],
  [
   "\\babhishek\\b",
   "Abhishek"
  ],
  [
   "\\bfast\\s+api\\b",
   "FastAPI"
  ],
  [
   "\\bnext\\s+j\\s+s\\b",
   "Next.js"
  ],
  [
   "\\bpostgres\\b",
   "PostgreSQL"
  ],
  [
   "\\bswift\\s+ui\\b",
   "SwiftUI"
  ],
  [
   "\\bCoderPad\\b",
   "CoderPad"
  ],
  [
   "\\bcoda\\s+pad\\b",
   "CoderPad"
  ],
  [
   "\\bEventKit\\b",
   "EventKit"
  ],
  [
   "\\bpb\\s+kdf\\s+2\\b",
   "PBKDF2"
  ],
  [
   "\\bPinecone\\b",
   "Pinecone"
  ],
  [
   "\\bchrome\\s+a\\b",
   "Chroma"
  ],
  [
   "\\bver\\s+cell\\b",
   "Vercel"
  ],
  [
   "\\bvor\\s+sell\\b",
   "Vercel"
  ],
  [
   "\\bshad\\s+c\\s+n\\b",
   "shadcn"
  ],
  [
   "\\bback\\s+net\\b",
   "BACnet"
  ],
  [
   "\\bvery\\s+log\\b",
   "Verilog"
  ],
  [
   "\\bvera\\s+log\\b",
   "Verilog"
  ],
  [
   "\\bar\\s+chive\\b",
   "arXiv"
  ],
  [
   "\\bSTEM\\s+OPT\\b",
   "STEM OPT"
  ],
  [
   "\\bstem\\s+opt\\b",
   "STEM OPT"
  ],
  [
   "\\bthe\\s+anza\\b",
   "De Anza"
  ],
  [
   "\\bLeetCode\\b",
   "LeetCode"
  ],
  [
   "\\bleetcode\\b",
   "LeetCode"
  ],
  [
   "\\bWisprit\\b",
   "Wisprit"
  ],
  [
   "\\bTaazify\\b",
   "Taazify"
  ],
  [
   "\\btaseefy\\b",
   "Taazify"
  ],
  [
   "\\btazzify\\b",
   "Taazify"
  ],
  [
   "\\bOmniSch\\b",
   "OmniSch"
  ],
  [
   "\\bwell\\s+ex\\b",
   "WellX"
  ],
  [
   "\\bo\\s+r\\s+i\\s+s\\b",
   "ORIS"
  ],
  [
   "\\bTalabat\\b",
   "Talabat"
  ],
  [
   "\\btelabat\\b",
   "Talabat"
  ],
  [
   "\\btalabot\\b",
   "Talabat"
  ],
  [
   "\\bflow\\s+71\\b",
   "Flow71"
  ],
  [
   "\\bheli\\s+ux\\b",
   "Heliux"
  ],
  [
   "\\bmercore\\b",
   "Mercor"
  ],
  [
   "\\bEliseAI\\b",
   "EliseAI"
  ],
  [
   "\\brubrick\\b",
   "Rubrik"
  ],
  [
   "\\bBaseten\\b",
   "Baseten"
  ],
  [
   "\\bbaseton\\b",
   "Baseten"
  ],
  [
   "\\bRevolut\\b",
   "Revolut"
  ],
  [
   "\\bh\\s+p\\s+e\\s+e\\b",
   "HPE"
  ],
  [
   "\\bkartike\\b",
   "Kartikey"
  ],
  [
   "\\bian\\s+roe\\b",
   "Ian Rowe"
  ],
  [
   "\\bian\\s+row\\b",
   "Ian Rowe"
  ],
  [
   "\\bShervin\\b",
   "Shervin"
  ],
  [
   "\\bsherwin\\b",
   "Shervin"
  ],
  [
   "\\bshervin\\b",
   "Shervin"
  ],
  [
   "\\bAgastya\\b",
   "Agastya"
  ],
  [
   "\\babishek\\b",
   "Abhishek"
  ],
  [
   "\\bFastAPI\\b",
   "FastAPI"
  ],
  [
   "\\bfastapi\\b",
   "FastAPI"
  ],
  [
   "\\bNext\\.js\\b",
   "Next.js"
  ],
  [
   "\\bnext\\s+js\\b",
   "Next.js"
  ],
  [
   "\\bSwiftUI\\b",
   "SwiftUI"
  ],
  [
   "\\bswiftui\\b",
   "SwiftUI"
  ],
  [
   "\\boh\\s+lama\\b",
   "Ollama"
  ],
  [
   "\\bo\\s+llama\\b",
   "Ollama"
  ],
  [
   "\\bAES\\-256\\b",
   "AES-256"
  ],
  [
   "\\bversell\\b",
   "Vercel"
  ],
  [
   "\\bshad\\s+cn\\b",
   "shadcn"
  ],
  [
   "\\bshatzen\\b",
   "shadcn"
  ],
  [
   "\\bbak\\s+net\\b",
   "BACnet"
  ],
  [
   "\\bVerilog\\b",
   "Verilog"
  ],
  [
   "\\bverilog\\b",
   "Verilog"
  ],
  [
   "\\barchive\\b",
   "arXiv"
  ],
  [
   "\\be\\s+c\\s+c\\s+v\\b",
   "ECCV"
  ],
  [
   "\\bh\\s+one\\s+b\\b",
   "H-1B"
  ],
  [
   "\\bCal\\.com\\b",
   "Cal.com"
  ],
  [
   "\\bcal\\s+com\\b",
   "Cal.com"
  ],
  [
   "\\bre\\s+send\\b",
   "Resend"
  ],
  [
   "\\bDe\\s+Anza\\b",
   "De Anza"
  ],
  [
   "\\bde\\s+anza\\b",
   "De Anza"
  ],
  [
   "\\bde\\s+onza\\b",
   "De Anza"
  ],
  [
   "\\bClaude\\b",
   "Claude"
  ],
  [
   "\\bshariq\\b",
   "Sharique"
  ],
  [
   "\\bsharik\\b",
   "Sharique"
  ],
  [
   "\\bshreek\\b",
   "Sharique"
  ],
  [
   "\\bKhatri\\b",
   "Khatri"
  ],
  [
   "\\bkathri\\b",
   "Khatri"
  ],
  [
   "\\btazify\\b",
   "Taazify"
  ],
  [
   "\\bomni\\s+s\\b",
   "OmniSch"
  ],
  [
   "\\bRamAIn\\b",
   "RamAIn"
  ],
  [
   "\\bremain\\b",
   "RamAIn"
  ],
  [
   "\\bwell\\s+x\\b",
   "WellX"
  ],
  [
   "\\bwellex\\b",
   "WellX"
  ],
  [
   "\\barchie\\b",
   "Aarki"
  ],
  [
   "\\baarchi\\b",
   "Aarki"
  ],
  [
   "\\bsierra\\b",
   "SEERA"
  ],
  [
   "\\baurora\\b",
   "Avora"
  ],
  [
   "\\ba\\s+vora\\b",
   "Avora"
  ],
  [
   "\\bFlow71\\b",
   "Flow71"
  ],
  [
   "\\bHeliux\\b",
   "Heliux"
  ],
  [
   "\\bhelios\\b",
   "Heliux"
  ],
  [
   "\\bletter\\b",
   "Letta"
  ],
  [
   "\\bMercor\\b",
   "Mercor"
  ],
  [
   "\\bmercor\\b",
   "Mercor"
  ],
  [
   "\\bnew\\s+ro\\b",
   "Nuro"
  ],
  [
   "\\bRubrik\\b",
   "Rubrik"
  ],
  [
   "\\brubric\\b",
   "Rubrik"
  ],
  [
   "\\brubrik\\b",
   "Rubrik"
  ],
  [
   "\\bchiron\\b",
   "Kyron Medical"
  ],
  [
   "\\bkairon\\b",
   "Kyron Medical"
  ],
  [
   "\\bbasten\\b",
   "Baseten"
  ],
  [
   "\\bemploy\\b",
   "Ploy"
  ],
  [
   "\\brevolt\\b",
   "Revolut"
  ],
  [
   "\\bKanika\\b",
   "Kanika"
  ],
  [
   "\\bcanica\\b",
   "Kanika"
  ],
  [
   "\\bkanica\\b",
   "Kanika"
  ],
  [
   "\\bkanika\\b",
   "Kanika"
  ],
  [
   "\\belelem\\b",
   "LLM"
  ],
  [
   "\\bnextjs\\b",
   "Next.js"
  ],
  [
   "\\be\\s+capa\\b",
   "ECAPA"
  ],
  [
   "\\bOllama\\b",
   "Ollama"
  ],
  [
   "\\braghas\\b",
   "Ragas"
  ],
  [
   "\\brag\\s+as\\b",
   "Ragas"
  ],
  [
   "\\bra\\s+gas\\b",
   "Ragas"
  ],
  [
   "\\bPBKDF2\\b",
   "PBKDF2"
  ],
  [
   "\\bfhighs\\b",
   "FAISS"
  ],
  [
   "\\bChroma\\b",
   "Chroma"
  ],
  [
   "\\bchroma\\b",
   "Chroma"
  ],
  [
   "\\bVercel\\b",
   "Vercel"
  ],
  [
   "\\bshadcn\\b",
   "shadcn"
  ],
  [
   "\\bBACnet\\b",
   "BACnet"
  ],
  [
   "\\bbacnet\\b",
   "BACnet"
  ],
  [
   "\\bar\\s+xiv\\b",
   "arXiv"
  ],
  [
   "\\bed\\s+gar\\b",
   "EDGAR"
  ],
  [
   "\\bResend\\b",
   "Resend"
  ],
  [
   "\\bresend\\b",
   "Resend"
  ],
  [
   "\\bm\\s+l\\s+x\\b",
   "MLX"
  ],
  [
   "\\bkatri\\b",
   "Khatri"
  ],
  [
   "\\bbibby\\b",
   "Bibi"
  ],
  [
   "\\bamman\\b",
   "Aman UAE"
  ],
  [
   "\\bahman\\b",
   "Aman UAE"
  ],
  [
   "\\bWellX\\b",
   "WellX"
  ],
  [
   "\\bwelex\\b",
   "WellX"
  ],
  [
   "\\bAarki\\b",
   "Aarki"
  ],
  [
   "\\bSEERA\\b",
   "SEERA"
  ],
  [
   "\\bseera\\b",
   "SEERA"
  ],
  [
   "\\bsarah\\b",
   "SEERA"
  ],
  [
   "\\borris\\b",
   "ORIS"
  ],
  [
   "\\bor\\s+is\\b",
   "ORIS"
  ],
  [
   "\\bAvora\\b",
   "Avora"
  ],
  [
   "\\bavora\\b",
   "Avora"
  ],
  [
   "\\bhelix\\b",
   "Heliux"
  ],
  [
   "\\bwhopp\\b",
   "Whop"
  ],
  [
   "\\bBland\\b",
   "Bland"
  ],
  [
   "\\bblend\\b",
   "Bland"
  ],
  [
   "\\bLetta\\b",
   "Letta"
  ],
  [
   "\\bletta\\b",
   "Letta"
  ],
  [
   "\\bneuro\\b",
   "Nuro"
  ],
  [
   "\\bkyron\\b",
   "Kyron Medical"
  ],
  [
   "\\bkiron\\b",
   "Kyron Medical"
  ],
  [
   "\\bx\\s+a\\s+i\\b",
   "xAI"
  ],
  [
   "\\bex\\s+ai\\b",
   "xAI"
  ],
  [
   "\\bh\\s+p\\s+e\\b",
   "HPE"
  ],
  [
   "\\br\\s+a\\s+g\\b",
   "RAG"
  ],
  [
   "\\bl\\s+l\\s+m\\b",
   "LLM"
  ],
  [
   "\\bm\\s+c\\s+p\\b",
   "MCP"
  ],
  [
   "\\bECAPA\\b",
   "ECAPA"
  ],
  [
   "\\becopa\\b",
   "ECAPA"
  ],
  [
   "\\bolama\\b",
   "Ollama"
  ],
  [
   "\\bquinn\\b",
   "Qwen"
  ],
  [
   "\\bq\\s+wen\\b",
   "Qwen"
  ],
  [
   "\\bqueen\\b",
   "Qwen"
  ],
  [
   "\\bRagas\\b",
   "Ragas"
  ],
  [
   "\\bragas\\b",
   "Ragas"
  ],
  [
   "\\bFAISS\\b",
   "FAISS"
  ],
  [
   "\\bfaiss\\b",
   "FAISS"
  ],
  [
   "\\bkroma\\b",
   "Chroma"
  ],
  [
   "\\barXiv\\b",
   "arXiv"
  ],
  [
   "\\bEDGAR\\b",
   "EDGAR"
  ],
  [
   "\\bedgar\\b",
   "EDGAR"
  ],
  [
   "\\be\\s+a\\s+d\\b",
   "EAD"
  ],
  [
   "\\bh\\s+1\\s+b\\b",
   "H-1B"
  ],
  [
   "\\bclod\\b",
   "Claude"
  ],
  [
   "\\bBibi\\b",
   "Bibi"
  ],
  [
   "\\bbebe\\b",
   "Bibi"
  ],
  [
   "\\baman\\b",
   "Aman UAE"
  ],
  [
   "\\barki\\b",
   "Aarki"
  ],
  [
   "\\bsera\\b",
   "SEERA"
  ],
  [
   "\\bORIS\\b",
   "ORIS"
  ],
  [
   "\\boris\\b",
   "ORIS"
  ],
  [
   "\\bWhop\\b",
   "Whop"
  ],
  [
   "\\bhwop\\b",
   "Whop"
  ],
  [
   "\\bleta\\b",
   "Letta"
  ],
  [
   "\\bNuro\\b",
   "Nuro"
  ],
  [
   "\\bnuro\\b",
   "Nuro"
  ],
  [
   "\\bPloy\\b",
   "Ploy"
  ],
  [
   "\\bplay\\b",
   "Ploy"
  ],
  [
   "\\bploy\\b",
   "Ploy"
  ],
  [
   "\\bx\\s+ai\\b",
   "xAI"
  ],
  [
   "\\brack\\b",
   "RAG"
  ],
  [
   "\\bl\\s+lm\\b",
   "LLM"
  ],
  [
   "\\bQwen\\b",
   "Qwen"
  ],
  [
   "\\bkwen\\b",
   "Qwen"
  ],
  [
   "\\bface\\b",
   "FAISS"
  ],
  [
   "\\bECCV\\b",
   "ECCV"
  ],
  [
   "\\beccv\\b",
   "ECCV"
  ],
  [
   "\\be\\s+ad\\b",
   "EAD"
  ],
  [
   "\\bH\\-1B\\b",
   "H-1B"
  ],
  [
   "\\bMLX\\b",
   "MLX"
  ],
  [
   "\\bb\\s+b\\b",
   "Bibi"
  ],
  [
   "\\baki\\b",
   "Aarki"
  ],
  [
   "\\bwop\\b",
   "Whop"
  ],
  [
   "\\bxAI\\b",
   "xAI"
  ],
  [
   "\\bHPE\\b",
   "HPE"
  ],
  [
   "\\bhpe\\b",
   "HPE"
  ],
  [
   "\\bRAG\\b",
   "RAG"
  ],
  [
   "\\brag\\b",
   "RAG"
  ],
  [
   "\\bLLM\\b",
   "LLM"
  ],
  [
   "\\bMCP\\b",
   "MCP"
  ],
  [
   "\\bmcp\\b",
   "MCP"
  ],
  [
   "\\bEAD\\b",
   "EAD"
  ],
  [
   "\\bead\\b",
   "EAD"
  ]
 ],
 "cases": [
  {
   "input": "i shipped insforge today",
   "expected": "i shipped InsForge today"
  },
  {
   "input": "INSFORGE and wisprit",
   "expected": "InsForge and Wisprit"
  },
  {
   "input": "swiftui and postgresql and fastapi",
   "expected": "SwiftUI and PostgreSQL and FastAPI"
  },
  {
   "input": "clod wrote the patch",
   "expected": "Claude wrote the patch"
  },
  {
   "input": "the rubric is strict",
   "expected": "the Rubrik is strict"
  },
  {
   "input": "we use neuro for driving",
   "expected": "we use Nuro for driving"
  },
  {
   "input": "put it in forge please",
   "expected": "put it InsForge please"
  },
  {
   "input": "run the meeting scribe helper",
   "expected": "run the MeetingScribe helper"
  },
  {
   "input": "whisper flow is the competitor",
   "expected": "Wispr Flow is the competitor"
  },
  {
   "input": "put it in    forge please",
   "expected": "put it InsForge please"
  },
  {
   "input": "put it in\tforge please",
   "expected": "put it InsForge please"
  },
  {
   "input": "whisper   flow is the competitor",
   "expected": "Wispr Flow is the competitor"
  },
  {
   "input": "i went to penn state university",
   "expected": "i went to Penn State"
  },
  {
   "input": "i went to pen state",
   "expected": "i went to Penn State"
  },
  {
   "input": "spot nana and spot nona",
   "expected": "Spotnana and Spotnana"
  },
  {
   "input": "kush boo khatri and khushboo katri",
   "expected": "Khushboo Khatri and Khushboo Khatri"
  },
  {
   "input": "reinforged steel is not in forge",
   "expected": "reinforged steel is not InsForge"
  },
  {
   "input": "clodhopper stayed clodhopper",
   "expected": "clodhopper stayed clodhopper"
  },
  {
   "input": "the rubrics were strict",
   "expected": "the rubrics were strict"
  },
  {
   "input": "CLOD and In Forge and WHISPER FLOW",
   "expected": "Claude and InsForge and Wispr Flow"
  },
  {
   "input": "we ran mlx whisper then faster whisper",
   "expected": "we ran MLX-whisper then faster-whisper"
  },
  {
   "input": "next js and cal dot com and h one b",
   "expected": "Next.js and Cal.com and H-1B"
  },
  {
   "input": "aes two fifty six with pbkdf two",
   "expected": "AES-256 with PBKDF2"
  },
  {
   "input": "hacker thought at pen state with in forge",
   "expected": "hackathon at Penn State with InsForge"
  },
  {
   "input": "I like summer and the weather is fine",
   "expected": "I like summer and the weather is fine"
  },
  {
   "input": "she said the answer was obvious",
   "expected": "she said the answer was obvious"
  },
  {
   "input": "",
   "expected": ""
  },
  {
   "input": "   ",
   "expected": "   "
  },
  {
   "input": "please archive the paper",
   "expected": "please arXiv the paper"
  },
  {
   "input": "the face recognition index",
   "expected": "the FAISS recognition index"
  },
  {
   "input": "we will resend the invite",
   "expected": "we will Resend the invite"
  },
  {
   "input": "scale ai and four hands and stem opt",
   "expected": "Scale AI and Four Hands and STEM OPT"
  },
  {
   "input": "alnaas advisory reviewed almosafer",
   "expected": "Alnaas Advisory reviewed Almosafer"
  },
  {
   "input": "danika voges joined",
   "expected": "D'nika Voges joined"
  },
  {
   "input": "in forge in forge in forge",
   "expected": "InsForge InsForge InsForge"
  },
  {
   "input": "insforge, insforge. insforge!",
   "expected": "InsForge, InsForge. InsForge!"
  },
  {
   "input": "(clod)",
   "expected": "(Claude)"
  }
 ],
 "writerSampleOutput": "{\n  \"terms\": [\n    {\n      \"term\": \"Sharique\",\n      \"hear\": [\n        \"Shariq\"\n      ],\n      \"hit_count\": 3,\n      \"note\": \"hand-written\"\n    },\n    {\n      \"term\": \"D'nika Voges\",\n      \"hear\": [],\n      \"learned_at\": \"2026-08-05T09:12:00Z\"\n    },\n    {\n      \"term\": \"Café über 日本\",\n      \"hear\": [\n        \"cafe uber nihon\"\n      ]\n    },\n    {\n      \"term\": \"quote\\\"back\\\\slash\",\n      \"hear\": [\n        \"tab\\there\",\n        \"nl\\nhere\",\n        \"ctrl\\u0001here\"\n      ]\n    }\n  ],\n  \"_comment\": \"unknown key survives\",\n  \"meta\": {\n    \"empty_obj\": {},\n    \"empty_arr\": [],\n    \"flag\": true,\n    \"missing\": null,\n    \"n\": -12\n  }\n}\n"
}
"""#
}

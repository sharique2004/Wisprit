import json,sys,urllib.request,re
def get(p):
    u="https://developer.apple.com/tutorials/data/documentation/"+p+".json"
    r=urllib.request.Request(u,headers={"User-Agent":"Mozilla/5.0"})
    return json.load(urllib.request.urlopen(r))
def txt(items):
    out=[]
    for it in items or []:
        t=it.get("type")
        if t=="text": out.append(it.get("text",""))
        elif t=="codeVoice": out.append("`"+it.get("code","")+"`")
        elif t=="reference": out.append(it.get("title") or it.get("identifier","").split("/")[-1])
        elif t=="emphasis" or t=="strong": out.append(txt(it.get("inlineContent")))
    return "".join(out)
def content(cs):
    out=[]
    for c in cs or []:
        k=c.get("kind") or c.get("type")
        if k=="paragraph": out.append(txt(c.get("inlineContent")))
        elif k=="heading": out.append("### "+c.get("text",""))
        elif k=="codeListing": out.append("```\n"+"\n".join(c.get("code",[]))+"\n```")
        elif k in("unorderedList","orderedList"):
            for i in c.get("items",[]): out.append(" - "+content(i.get("content")))
        elif k=="aside": out.append("[ASIDE "+str(c.get("name"))+"] "+content(c.get("content")))
        elif k=="termList":
            for i in c.get("items",[]): out.append(" * "+txt(i.get("term",{}).get("inlineContent"))+": "+content(i.get("definition",{}).get("content")))
    return "\n".join(out)
for p in sys.argv[1:]:
    d=get(p)
    print("\n\n########",p)
    md=d.get("metadata",{})
    print("TITLE:",md.get("title"),"|",md.get("symbolKind"))
    for pl in md.get("platforms",[]) or []:
        print("  PLATFORM:",pl.get("name"),pl.get("introducedAt"),"beta" if pl.get("beta") else "","deprecated" if pl.get("deprecated") else "")
    print("ABSTRACT:",txt(d.get("abstract")))
    for s in d.get("primaryContentSections",[]):
        if s.get("kind")=="declarations":
            for dec in s.get("declarations",[]):
                print("DECL:", "".join(t.get("text","") for t in dec.get("tokens",[])))
        elif s.get("kind")=="content":
            print(content(s.get("content")))
        elif s.get("kind")=="parameters":
            for pa in s.get("parameters",[]): print("PARAM",pa.get("name"),":",content(pa.get("content")))
    refs=d.get("references",{})
    for ts in d.get("topicSections",[]):
        print("--",ts.get("title"))
        for i in ts.get("identifiers",[]):
            r=refs.get(i,{})
            frag="".join(t.get("text","") for t in (r.get("fragments") or []))
            print("   *",r.get("title"),"|",frag,"|",txt(r.get("abstract")))

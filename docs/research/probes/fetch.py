import json,sys,urllib.request
def get(slug):
    url="https://developer.apple.com/tutorials/data/documentation/"+slug+".json"
    req=urllib.request.Request(url,headers={'User-Agent':'Mozilla/5.0'})
    try:
        d=json.load(urllib.request.urlopen(req,timeout=30))
    except Exception as e:
        print("ERR",slug,e); return
    out=[]
    def walk(o):
        if isinstance(o,dict):
            t=o.get('type')
            if t=='text': out.append(o.get('text',''))
            elif t=='codeVoice': out.append('`'+o.get('code','')+'`')
            elif t=='heading': out.append('\n## '+o.get('text','')+'\n')
            elif t=='codeListing': out.append('\n'+'\n'.join(o.get('code',[]))+'\n')
            elif t=='paragraph': out.append('\n')
            for v in o.values(): walk(v)
        elif isinstance(o,list):
            for v in o: walk(v)
    walk(d.get('primaryContentSections',[]))
    walk(d.get('abstract',[]))
    print("="*20,slug,"="*20)
    print(''.join(out)[:6000])
for s in sys.argv[1:]: get(s)

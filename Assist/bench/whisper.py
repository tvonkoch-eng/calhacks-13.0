import json,os,sys,time,urllib.request,uuid,concurrent.futures as cf
KEY=[l.split('=')[1].strip() for l in open('/root/workspace/calhacks-13.0/Secrets.xcconfig') if 'ANSWER_API_KEY' in l][0]
VOCAB="Cal Hacks, Berkeley, Groq, Joaquin, Mirabelle, Toby, Avi, Presidio, Palace of Fine Arts, Meta Ray-Ban."
def tx(path, model, prompt):
    b=uuid.uuid4().hex; data=open(path,'rb').read()
    parts=[]
    for k,v in [("model",model),("language","en"),("temperature","0"),("response_format","json")]+([("prompt",prompt)] if prompt else []):
        parts.append(f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
    parts.append(f'--{b}\r\nContent-Disposition: form-data; name="file"; filename="a.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode()+data+b'\r\n')
    body=b''.join(parts)+f'--{b}--\r\n'.encode()
    for a in range(5):
        try:
            t=time.time()
            r=urllib.request.urlopen(urllib.request.Request("https://api.groq.com/openai/v1/audio/transcriptions",data=body,headers={"Authorization":f"Bearer {KEY}","Content-Type":f"multipart/form-data; boundary={b}","User-Agent":"x/1"}),timeout=30)
            return json.load(r)["text"].strip(), time.time()-t
        except Exception as e:
            time.sleep(2+a*2)
    return "", 0
for model,tag,prompt in [("whisper-large-v3-turbo","turboPrompt",VOCAB),("whisper-large-v3","v3Prompt",VOCAB),("whisper-large-v3-turbo","turbo",None)]:
    for c in ["clean","noisy10","noisy5far"]:
        files=sorted(os.listdir(f"clips/{c}"))
        with cf.ThreadPoolExecutor(4) as ex:
            res=list(ex.map(lambda f: tx(f"clips/{c}/{f}",model,prompt), files))
        with open(f"out-{tag}-{c}.jsonl","w") as o:
            for f,(t,lat) in zip(files,res): o.write(json.dumps({"file":f"clips/{c}/{f}","text":t,"lat":lat})+"\n")
        lats=sorted(l for _,l in res if l); print(tag,c,"median latency %.2fs"%lats[len(lats)//2], flush=True)

"""Original code-drawn Okiru movement icon; no external imagery or font licensing."""
from pathlib import Path
import json, math, struct, zlib

root = Path(__file__).resolve().parents[1]/'Resources/Assets.xcassets/AppIcon.appiconset'
root.mkdir(parents=True,exist_ok=True)
size = 1024
def segment(x,y,ax,ay,bx,by,r):
    dx,dy=bx-ax,by-ay
    t=max(0,min(1,((x-ax)*dx+(y-ay)*dy)/(dx*dx+dy*dy)))
    return math.hypot(x-ax-t*dx,y-ay-t*dy)-r
def circle(x,y,cx,cy,r): return math.hypot(x-cx,y-cy)-r
def alpha(distance): return max(0,min(1,.5-distance))
def blend(base,paint,amount): return tuple(round(a*(1-amount)+b*amount) for a,b in zip(base,paint))
rows=bytearray()
for y in range(size):
    rows.append(0)
    for x in range(size):
        # A distinctive Okiru "O" surrounds a person completing a push-up.
        # The composition avoids generic clock, bell and sunrise silhouettes.
        px,py=x+.5,y+.5
        t=(x+y)/(size*2)
        color=(22+round(20*t),23+round(8*t),49+round(23*t))
        ring=abs(math.hypot(px-512,py-505)-316)-43
        color=blend(color,(255,104,54),alpha(ring))
        # Far arm adds depth but stays subordinate to the main cream figure.
        far_arm=min(segment(px,py,432,468,535,570,23),segment(px,py,535,570,615,584,23))
        color=blend(color,(211,72,52),alpha(far_arm))
        figure=min(
            circle(px,py,334,405,50),
            segment(px,py,392,455,640,520,33),
            segment(px,py,640,520,793,584,29),
            segment(px,py,427,468,495,610,25),
            segment(px,py,495,610,590,610,25))
        color=blend(color,(255,245,219),alpha(figure))
        ground=segment(px,py,226,676,806,676,16)
        color=blend(color,(255,176,83),alpha(ground))
        rows.extend(color)
def chunk(kind,data): return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',size,size,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(rows,9))+chunk(b'IEND',b'')
(root/'AppIcon.png').write_bytes(png)
(root/'Contents.json').write_text(json.dumps({'images':[{'filename':'AppIcon.png','idiom':'universal','platform':'ios','size':'1024x1024'}],'info':{'author':'xcode','version':1}},indent=2))
print(root/'AppIcon.png')

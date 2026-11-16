import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch
from PIL import Image
import io
BG="#FFF8EE"; INK="#2B2118"; MUTED="#8A7B6C"; CARD="#FFFFFF"; LINE="#E6D7C3"
COCOON="#E8833A"; SOFT="#FCE3CF"; GREEN="#5B8C5A"
def varint(n):
    out=[]
    while True:
        b=n&0x7f; n>>=7
        if n: out.append(b|0x80)
        else: out.append(b); return out
zz=lambda v:(v<<1)^(v>>63)
# Generated codecs write every int as sint64 (zigzag), fields in ascending number.
blob=[0x08]+varint(zz(20261111))+[0x10]+varint(zz(-1250))
hexs=" ".join(f"{b:02x}" for b in blob)
W,H,DPI=10,5.6,105
steps=[
 ("1","Your object","Txn(bookedOn: 20261111,\n    amountMinor: -1250)","plain Dart, no Map, no SQL"),
 ("2","Canonical protobuf",hexs,f"{len(blob)} bytes · field numbers from cocoon.lock"),
 ("3","A row in the txns table","accountId  a1\nid         0193…e7 (UUIDv7)\ndata       "+hexs[:14]+"…\nbookedOn   20261111","indexed fields → columns"),
 ("4","Index: accountId, -bookedOn","a1 · 20261111  ← new\na1 · 20261108\na1 · 20261030","latest 50 = a short walk"),
 ("5","Change log","seq 1042  set\naccounts/a1/txns/t1","feeds watches + sync"),
 ("6","watch() fires","your list re-renders","after the commit, only for this collection"),
]
pos=[(3,30),(36,30),(69,30),(3,3),(36,3),(69,3)]
def draw(n_shown, alpha_last, final=False):
    fig=plt.figure(figsize=(W,H),dpi=DPI,facecolor=BG)
    ax=fig.add_axes([0,0,1,1]); ax.set_xlim(0,100); ax.set_ylim(0,62); ax.axis("off")
    ax.text(3,58,"What happens on  ",fontsize=16,weight="bold",color=INK,va="center")
    ax.text(30.5,58,"await txns.doc('t1').set(txn)",fontsize=14,color=COCOON,va="center",family="DejaVu Sans Mono",weight="bold")
    ax.text(3,54.2,"Behind the scenes. Steps 3 to 5 commit together in one SQLite transaction: all of it, or none of it.",fontsize=10.5,color=MUTED,va="center")
    for i,(num,title,body,note) in enumerate(steps[:n_shown]):
        a=alpha_last if i==n_shown-1 else 1.0
        x,y=pos[i]; w,h=28,21
        hot = (i==n_shown-1) and not final
        ax.add_patch(FancyBboxPatch((x,y),w,h,boxstyle="round,pad=0,rounding_size=1.6",fc=SOFT if hot else CARD,ec=COCOON if hot else LINE,lw=1.6,alpha=a))
        ax.add_patch(plt.Circle((x+3,y+h-3),1.9,color=COCOON,alpha=a))
        ax.text(x+3,y+h-3,num,fontsize=10,color="white",ha="center",va="center",weight="bold",alpha=a)
        ax.text(x+6,y+h-3,title,fontsize=11,color=INK,va="center",weight="bold",alpha=a)
        ax.text(x+2,y+h-7,body,fontsize=9.2,color=INK,va="top",family="DejaVu Sans Mono",alpha=a,linespacing=1.35)
        if i in (2,3,4):
            ax.add_patch(FancyBboxPatch((x+w-9.2,y+1.2),8.2,2.8,boxstyle="round,pad=0,rounding_size=1.2",fc="#E3EEDF",ec="none",alpha=a))
            ax.text(x+w-5.1,y+2.6,"same txn",fontsize=7.6,color=GREEN,ha="center",va="center",weight="bold",alpha=a)
        ax.text(x+2,y+1.8,note,fontsize=8.6,color=MUTED,va="bottom",style="italic",alpha=a)
        if i>0:
            px,py=pos[i-1]
            if py==y: s,e=(px+28.4,y+10.5),(x-0.4,y+10.5)
            else: s,e=(px+14,py-0.3),(x+14,y+21.3)
            if i==3: s,e=(pos[2][0]+2,pos[2][1]-0.3),(x+26,y+21.3)
            ax.add_patch(FancyArrowPatch(s,e,arrowstyle="-|>",mutation_scale=13,color=COCOON,lw=1.6,alpha=a,connectionstyle="arc3,rad=0.0" if i!=3 else "arc3,rad=0.12"))
    buf=io.BytesIO(); fig.savefig(buf,format="png",facecolor=BG); plt.close(fig); buf.seek(0)
    return Image.open(buf).convert("RGB")
fr=[draw(0,1)];d=[700]
for n in range(1,7):
    for a in (0.25,0.55,0.85): fr.append(draw(n,a)); d.append(70)
    fr.append(draw(n,1.0)); d.append(1500)
fr.append(draw(6,1.0,True)); d.append(4500)
pal=[f.quantize(colors=48,method=Image.Quantize.MEDIANCUT) for f in fr]
pal[0].save("cocoon_set_behind_the_scenes.gif",save_all=True,append_images=pal[1:],duration=d,loop=0,optimize=True)
print(hexs)

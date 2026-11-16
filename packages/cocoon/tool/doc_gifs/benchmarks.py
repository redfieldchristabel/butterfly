import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch
from PIL import Image
import io, numpy as np
BG="#FFF8EE"; INK="#2B2118"; MUTED="#8A7B6C"; TRACK="#F0E4D3"
COCOON="#E8833A"; OTHER="#B9A693"; DONEBAR="#D9CBBB"
W,H,DPI=9.0,4.8,110
def canvas():
    fig=plt.figure(figsize=(W,H),dpi=DPI,facecolor=BG)
    ax=fig.add_axes([0,0,1,1]); ax.set_xlim(0,100); ax.set_ylim(0,54); ax.axis("off"); return fig,ax
def png(fig):
    buf=io.BytesIO(); fig.savefig(buf,format="png",facecolor=BG); plt.close(fig); buf.seek(0); return Image.open(buf).convert("RGB")
def save(frames,durs,path):
    pal=[f.quantize(colors=48,method=Image.Quantize.MEDIANCUT) for f in frames]
    pal[0].save(path,save_all=True,append_images=pal[1:],duration=durs,loop=0,optimize=True)
# ---------- race ----------
eng=[("drift (raw SQL)",0.5),("Cocoon",0.7),("ObjectBox",44.4),("Isar",55.5),("Hive CE",710.5),("sembast",796.3)]
TMAX=800.0
def race(t,final=False):
    fig,ax=canvas()
    ax.text(4,49.5,"Latest 50 transactions for one account",fontsize=17,weight="bold",color=INK,va="center")
    ax.text(4,45.3,"1,000,000 transactions on device  ·  p50  ·  rivals matrix v2, Nov 2026",fontsize=10.5,color=MUTED,va="center")
    ax.text(96,49.5,f"{min(t,TMAX):4.0f} ms",fontsize=17,weight="bold",color=INK,ha="right",va="center",family="DejaVu Sans Mono")
    ax.text(96,45.3,"clock",fontsize=9.5,color=MUTED,ha="right",va="center")
    x0,x1=24,70
    for i,(n,ms) in enumerate(eng):
        y=38-i*5.9; c=n=="Cocoon"
        ax.text(x0-2,y,n,fontsize=13,ha="right",va="center",color=INK,weight="bold" if c else "normal")
        ax.add_patch(FancyBboxPatch((x0,y-1.9),x1-x0,3.8,boxstyle="round,pad=0,rounding_size=1.7",fc=TRACK,ec="none"))
        p=min(t/ms,1) if t>0 else 0
        if p>0:
            col=COCOON if c else (DONEBAR if p>=1 else OTHER)
            ax.add_patch(FancyBboxPatch((x0,y-1.9),max((x1-x0)*p,2.2),3.8,boxstyle="round,pad=0,rounding_size=1.7",fc=col,ec="none"))
        if p>=1:
            if c: ax.text(x1+1.5,y,"✓ 0.7 ms",fontsize=13,va="center",color=COCOON,weight="bold")
            elif ms<0.7:
                ax.text(x1+1.5,y,f"{ms:g} ms",fontsize=12,va="center",color=INK)
                ax.text(x1+12.5,y,"hand-written SQL",fontsize=9.5,va="center",color=MUTED)
            else:
                ax.text(x1+1.5,y,f"{ms:g} ms",fontsize=12,va="center",color=INK)
                ax.text(x1+12.5,y,f"{ms/0.7:,.0f}× slower",fontsize=10.5,va="center",color=MUTED)
        else:
            ax.text(x1+1.5,y,"scanning…",fontsize=11,va="center",color=MUTED,style="italic")
    if final:
        ax.text(50,2.6,"Typed documents at nearly raw-SQL speed.  The in-RAM engines scan every record.",fontsize=11,ha="center",va="center",color=INK,weight="bold")
    return png(fig)
fr=[race(0)];d=[600]
fr.append(race(1.0));d.append(1100)
for t in np.geomspace(3,TMAX,46): fr.append(race(t));d.append(65)
fr.append(race(TMAX,True));d.append(4000)
save(fr,d,"cocoon_latest50_race.gif")
# ---------- RAM ----------
ram=[("drift",-25),("Cocoon",2),("Isar",305),("ObjectBox",546),("Hive CE",2057),("sembast",2298)]
def lab(mb): return f"−{-mb:.0f} MB" if mb<0 else (f"+{mb/1000:.1f} GB" if mb>=1000 else f"+{mb:.0f} MB")
def ramf(p,final=False):
    fig,ax=canvas()
    ax.text(4,49.5,"Extra RAM after the read workloads",fontsize=17,weight="bold",color=INK,va="center")
    ax.text(4,45.3,"1,000,000 transactions  ·  minus a measured harness baseline  ·  Nov 2026",fontsize=10.5,color=MUTED,va="center")
    base=8; top=37; xs=[10,26.5,43,59.5,76,92.5]
    for (n,mb),x in zip(ram,xs):
        c=n=="Cocoon"; h=(top-base)*max(0,min(1,mb/2298*p))
        ax.add_patch(FancyBboxPatch((x-5.5,base),11,top-base,boxstyle="round,pad=0,rounding_size=1.5",fc=TRACK,ec="none"))
        if h>0 and mb>0: ax.add_patch(FancyBboxPatch((x-5.5,base),11,max(h,0.6),boxstyle="round,pad=0,rounding_size=1.0",fc=COCOON if c else OTHER,ec="none"))
        ax.text(x,base-3,n,fontsize=12,ha="center",va="center",color=INK,weight="bold" if c else "normal")
        ax.text(x,base+max(h,0.6)+2.2,lab(mb*p if not final else mb) if p>0 else "",fontsize=12 if not c else 13,ha="center",va="center",color=COCOON if c else INK,weight="bold" if c else "normal")
    if final: ax.text(50,1.3,"Data stays on disk. Only a small cache of hot documents lives in memory.",fontsize=10.5,ha="center",va="center",color=INK)
    return png(fig)
fr=[ramf(0)];d=[500]
for p in np.linspace(0.04,1,32): fr.append(ramf(1-(1-p)**2));d.append(55)
fr.append(ramf(1,True));d.append(4000)
save(fr,d,"cocoon_ram.gif")

#!/usr/bin/env python3
# Dump the view tree of a compiled NIBArchive nib: classes, frames, titles, fonts and
# Auto Layout constraints. This is how the inspector's measurements were read from
# Keynote (Sources/PhrasoApp/StyleViews.swift, `Pane`):
#
#   python3 Tools/nibdump.py "/Applications/Keynote Creator Studio.app/Contents/Resources/Base.lproj/TMATextInspector.nib"
#   python3 Tools/nibdump.py file.nib raw      every object with its first keys
import struct, sys
d=open(sys.argv[1],'rb').read()
assert d[:10]==b'NIBArchive'
h=struct.unpack('<10I',d[10:50])
_,_,nobj,oobj,nkey,okey,nval,oval,ncls,ocls=h
def vint(p):
    v=0;s=0
    while True:
        b=d[p];p+=1
        v|=(b&0x7f)<<s;s+=7
        if b&0x80: return v,p
p=oobj;objs=[]
for i in range(nobj):
    c,p=vint(p);vi,p=vint(p);vc,p=vint(p);objs.append((c,vi,vc))
p=okey;keys=[]
for i in range(nkey):
    l,p=vint(p);keys.append(d[p:p+l].decode());p+=l
p=oval;vals=[]
for i in range(nval):
    k,p=vint(p);t=d[p];p+=1
    if t==0: v=struct.unpack('<b',d[p:p+1])[0];p+=1
    elif t==1: v=struct.unpack('<h',d[p:p+2])[0];p+=2
    elif t==2: v=struct.unpack('<i',d[p:p+4])[0];p+=4
    elif t==3: v=struct.unpack('<q',d[p:p+8])[0];p+=8
    elif t==4: v=True
    elif t==5: v=False
    elif t==6: v=struct.unpack('<f',d[p:p+4])[0];p+=4
    elif t==7: v=struct.unpack('<d',d[p:p+8])[0];p+=8
    elif t==8: l,p=vint(p);v=d[p:p+l];p+=l
    elif t==9: v=None
    elif t==10: v=('@',struct.unpack('<I',d[p:p+4])[0]);p+=4
    else: raise Exception(t)
    vals.append((keys[k],v))
p=ocls;clss=[]
for i in range(ncls):
    l,p=vint(p);e,p=vint(p);p+=4*e;clss.append(d[p:p+l-1].decode());p+=l
def O(i):
    c,vi,vc=objs[i];return clss[c],vals[vi:vi+vc]
def get(i,k,default=None):
    for kk,v in O(i)[1]:
        if kk==k: return v
    return default
def items(i):
    return [v[1] for k,v in O(i)[1] if k=='UINibEncoderEmptyKey' and isinstance(v,tuple)]
def S(v):
    if isinstance(v,tuple):
        c,vs=O(v[1])
        for k,x in vs:
            if k=='NS.bytes': return x.decode('utf8','replace')
        for k,x in vs:
            if k in('NSContents','NSTitle'): return S(x)
        return c
    return v
def rect(b):
    if isinstance(b,bytes):
        n=len(b)//8
        if len(b)%8==0 and n in(2,4): return tuple(round(x,1) for x in struct.unpack('<%dd'%n,b))
        if b and b[0] in (7,): 
            pass
        return b.hex()
    return S(b)
ATTR={0:'none',1:'left',2:'right',3:'top',4:'bottom',5:'lead',6:'trail',7:'W',8:'H',9:'cX',10:'cY',11:'base',12:'fbase'}
def lab(i):
    c,vs=O(i);dv=dict(vs);t=''
    cn=dv.get('NSClassName')
    if cn: c=S(cn)
    cell=dv.get('NSCell')
    if cell:
        cd=dict(O(cell[1])[1])
        v=cd.get('NSContents') or cd.get('NSTitle')
        if v is not None: t+=' "%s"'%str(S(v))[:40]
        f=cd.get('NSSupport')
        if f:
            fd=dict(O(f[1])[1]);t+=' font=%s/%s'%(S(fd.get('NSName')),fd.get('NSSize'))
        for k in('NSControlSize2','NSControlSize'):
            if k in cd: t+=' cs=%s'%cd[k]
    if 'NSTitle' in dv: t+=' title="%s"'%S(dv['NSTitle'])
    return '%s#%d%s'%(c,i,t)
def walk(i,dp=0):
    c,vs=O(i);dv=dict(vs)
    fr=rect(dv.get('NSFrame',dv.get('NSFrameSize','')))
    print('  '*dp+lab(i),fr)
    cons=dv.get('NSViewConstraints')
    if cons:
        for ci in items(cons[1]):
            cd=dict(O(ci)[1])
            print('  '*(dp+1)+'~ %s.%s %s %s.%s x%s + %s p%s'%(lab(cd['NSFirstItem'][1]).split(' ')[0] if cd.get('NSFirstItem') else '-',ATTR.get(cd.get('NSFirstAttribute',cd.get('NSFirstAttributeV2',0)),'?'),{-1:'<=',0:'==',1:'>='}.get(cd.get('NSRelation',0),'=='),lab(cd['NSSecondItem'][1]).split(' ')[0] if cd.get('NSSecondItem') else '-',ATTR.get(cd.get('NSSecondAttribute',cd.get('NSSecondAttributeV2',0)),'?'),cd.get('NSMultiplier',1),cd.get('NSConstant',cd.get('NSConstantV2',0)),cd.get('NSPriority',1000)))
    sub=dv.get('NSSubviews')
    if sub:
        for x in items(sub[1]): walk(x,dp+1)
if len(sys.argv)>2 and sys.argv[2]=='raw':
    for i in range(nobj):
        c,vs=O(i);print(i,c,[(k,(v if not isinstance(v,bytes) else rect(v))) for k,v in vs][:14])
else:
    for i in range(nobj):
        c,vs=O(i);dv=dict(vs)
        if 'NSSubviews' in dv and 'NSSuperview' not in dv: print('== root');walk(i)

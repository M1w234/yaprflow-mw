# Original yaprflow cues. Reproducible with Python standard library. Apache-2.0.
import math,wave,struct
from pathlib import Path
out=Path(__file__).resolve().parents[1]/'src/YaprFlow.Windows/Assets/Sounds'
for preset,duration,decay,modes in [('soft',.13,.025,[(540,1),(1080,.08)]),('wood',.09,.014,[(720,1),(1154,.4),(1860,.12)]),('glass',.22,.05,[(880,1),(1760,.18),(2640,.045)])]:
 for starting in [True,False]:
  pitch=1 if starting else .75;rate=24000;values=[]
  for i in range(round(rate*duration)):
   t=i/rate
   attack=1-math.exp(-t/.0025)
   tail=min(1,(duration-t)/.015)
   value=sum(a*math.sin(2*math.pi*f*pitch*t)*math.exp(-t/(decay/(1+k*.25))) for k,(f,a) in enumerate(modes))
   values.append(value*attack*tail)
  peak=max(map(abs,values));values=[x*.19/peak for x in values]
  with wave.open(str(out/f'{preset}-{"start" if starting else "stop"}.wav'),'wb') as w:
   w.setparams((1,2,rate,len(values),'NONE','not compressed'));w.writeframes(b''.join(struct.pack('<h',round(x*32767)) for x in values))

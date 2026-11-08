#!/usr/bin/env python3
# SPDX-License-Identifier: SHL-0.51
"""Check actual handshakes with an independent exact IEEE oracle for these inputs."""
from pathlib import Path
from fractions import Fraction
import re,json,hashlib,sys,math,collections

def fields(line):return dict(re.findall(r'(\w+)=([^ ]+)',line))
def decode(value,width):
 eb={16:5,32:8,64:11}[width];mb=width-eb-1;sign=-1 if value>>(width-1)else 1;e=(value>>mb)&((1<<eb)-1);m=value&((1<<mb)-1);bias=(1<<(eb-1))-1
 if e==(1<<eb)-1:return ('nan'if m else'inf',sign,None)
 if not e:x=Fraction(m,1<<mb);power=1-bias
 else:x=Fraction((1<<mb)+m,1<<mb);power=e-bias
 return ('finite',sign,sign*x*(Fraction(1<<power)if power>=0 else Fraction(1,1<<-power)))
def encode_exact(x,width):
 if not x:return 0
 eb={16:5,32:8,64:11}[width];mb=width-eb-1;bias=(1<<(eb-1))-1;sgn=int(x<0);x=abs(x);e=x.numerator.bit_length()-x.denominator.bit_length()
 scale=Fraction(1<<e)if e>=0 else Fraction(1,1<<-e)
 if x<scale:e-=1;scale/=2
 mantissa=(x/scale-1)*(1<<mb);assert mantissa.denominator==1 and 0<e+bias<(1<<eb)-1
 return(sgn<<(width-1))|((e+bias)<<mb)|int(mantissa)
def gold(row):
 w=row['width'];n=64//w if row['vec']else 1;upper=((1<<64)-1)^((1<<w)-1);flags=0;expected=[]
 for lane in range(n):
  if not(row['mask']>>(lane*w//16)&1):continue
  a=(row['a']>>(lane*w))&((1<<w)-1);b=(row['b']>>(lane*w))&((1<<w)-1)
  unboxed=not row['vec']and w<64 and ((row['a']&upper)!=upper or (row['op']=='DIV'and(row['b']&upper)!=upper))
  ka,sa,x=decode(a,w);kb,sb,y=decode(b,w);ff=0
  if unboxed or ka=='nan' or (row['op']=='DIV'and kb=='nan'):kind='qnan';z=None
  elif row['op']=='SQRT'and x<0:kind='qnan';z=None;ff=16
  elif row['op']=='DIV'and y==0:
   assert x!=0,'No active 0/0: separate MVP bug must remain outside this test'
   kind='exact';eb={16:5,32:8,64:11}[w];mb=w-eb-1;z=((1<<(eb))-1)<<mb;ff=8
  else:
   kind='exact'
   if row['op']=='DIV':z=encode_exact(x/y,w)
   else:
    num=math.isqrt(x.numerator);den=math.isqrt(x.denominator);assert num*num==x.numerator and den*den==x.denominator;z=encode_exact(Fraction(num,den),w)
  flags|=ff;expected.append((lane,kind,z))
 return flags,expected

def review(log,rows,require_holds=False):
 text=Path(log).read_text();integrity=[];errors=[];checks=0
 def must(good,label):
  nonlocal checks
  checks+=1
  if not good:integrity.append(label)
 def check(good,label):
  nonlocal checks
  checks+=1
  if not good:errors.append(label)
 inputs=[fields(x)for x in text.splitlines()if x.startswith('[INPUT] ')];outputs=[fields(x)for x in text.splitlines()if x.startswith('[OUTPUT] ')];cases=[fields(x)for x in text.splitlines()if x.startswith('[DIVSQRT_MASK_CASE] ')];done=[fields(x)for x in text.splitlines()if x.startswith('[DIVSQRT_MASK_DONE] ')];holds=[fields(x)for x in text.splitlines()if x.startswith('[HOLD] ')]
 N=len(rows);must(len(cases)==N,'case_count');must(len(done)==1,'unique_done');must([int(x['id'])for x in cases]==list(range(1,N+1)),'case_ID_sequence');must(bool(re.search(r'\$finish at simulation time\s+\d+',text)),'native_finish');must(not re.search(r'Error-|HDL_TIMEOUT|Too many pending|Assertion.*failed|UCLI.*error',text,re.I),'no_DUT_error_or_timeout')
 if done:
  d=done[0];must(d.get('accepted')==str(N)and d.get('completed')==str(N)and d.get('protocol_errors')=='0'and d.get('busy')=='0'and d.get('timeout')=='0','completed_idle_no_protocol_error');must(int(d['failed_cases'])==sum(' FAIL'in x for x in text.splitlines()if x.startswith('[DIVSQRT_MASK_CASE] ')),'TB_summary_matches_cases')
 if inputs or any(row.get('expect_handshake_prints',False) for row in rows):
  must(len(inputs)==N and len(outputs)==N,'actual_handshake_counts');must([int(x['id'])for x in inputs]==list(range(1,N+1))and[int(x['id'])for x in outputs]==list(range(1,N+1)),'actual_once_per_tag')
 for row,case in zip(rows,cases):
  ident=row['id'];w=row['width'];must(case['fmt']==row['fmt']and int(case['vec'])==row['vec']and int(case['mask'],2)==row['mask']and int(case['tag'])==ident,'case_input_binding_%d'%ident)
  if inputs and ident<=len(inputs):
   a=inputs[ident-1];must(a['op']==row['op']and a['fmt']==row['fmt']and int(a['vec'])==row['vec']and int(a['mask'],2)==row['mask']and int(a['a'],16)==row['a']and int(a['b'],16)==row['b'],'actual_input_%d'%ident)
  try:value=int(case['got'],16);status=int(case['flags'],16)
  except ValueError:must(False,'unknown_result_%d'%ident);continue
  if outputs and ident<=len(outputs):must(int(outputs[ident-1]['result'],16)==value and int(outputs[ident-1]['flags'],16)==status,'actual_output_%d'%ident)
  flags,parts=gold(row);check(status==flags,'flags_%d_got%02x_expected%02x'%(ident,status,flags))
  if not row['vec']and w<64:check(value>>w==(1<<(64-w))-1,'output_nan_box_%d'%ident)
  for lane,kind,z in parts:
   got=(value>>(lane*w))&((1<<w)-1)
   if kind=='exact':check(got==z,'result_%d_lane%d'%(ident,lane))
   else:
    eb={16:5,32:8,64:11}[w];mb=w-eb-1;check(((got>>mb)&((1<<eb)-1))==(1<<eb)-1 and bool(got&(1<<(mb-1))),'qnan_%d_lane%d'%(ident,lane))
  check(case.get('want_flags')==('%02x'%flags),'TB_flags_agree_independent_%d'%ident)
 if require_holds:
  counts=collections.Counter(int(x['id'])for x in holds);expected={row['id']:3 for row in rows if row.get('stall')};must(dict(counts)==expected,'all_three_cycle_holds_observed')
  for x in holds:
   ident=int(x['id'])
   if not 1<=ident<=len(outputs):must(False,'held_output_missing_%d'%ident);continue
   o=outputs[ident-1];must(x['valid']=='1'and x['tag']==x['id']and x['result']==o['result']and x['flags']==o['flags'],'held_payload_%d'%ident)
 return {'log':str(log),'sha256':hashlib.sha256(Path(log).read_bytes()).hexdigest(),'cases':N,'actual_input_records':len(inputs),'actual_output_records':len(outputs),'hold_records':len(holds),'checks':checks,'integrity_errors':integrity,'functional_errors':errors,'TB_failed_cases':int(done[0]['failed_cases'])if done else None,'accepted':not integrity and not errors,'out_of_scope_failures':'qNaN input boxing probe failures are separate from the mask candidate if this is the probe group'}
def rows_from_tb(path):
 text=Path(path).read_text();rows=[]
 def number(token):
  token=token.strip();m=re.fullmatch(r"[0-9]+'([bdh])([0-9a-fA-F_]+)",token)
  return int(m.group(2).replace('_',''),{'b':2,'d':10,'h':16}[m.group(1)]) if m else int(token)
 for m in re.finditer(r"\brun_case\((\d+),([\s\S]*?)\);",text):
  args=(m.group(1)+','+m.group(2)).split(',');fmt=args[3].strip();rows.append({'id':number(args[0]),'label':args[1].strip().strip('"'),'op':args[2].strip(),'fmt':fmt,'width':int(fmt[2:]),'vec':number(args[4]),'mask':number(args[5]),'a':number(args[6]),'b':number(args[7]),'expect_handshake_prints':'[INPUT]' in text,'stall':len(args)>12 and bool(number(args[12]))})
 return rows
if __name__=='__main__':
 log=Path(sys.argv[1]);source=Path(sys.argv[2]);rows=json.loads(source.read_text()) if source.suffix=='.json' else rows_from_tb(source);result=review(log,rows,'--holds' in sys.argv[3:]);print(json.dumps(result,indent=2));sys.exit(0 if result['accepted']else 1)

"""Exact captured-window activity and full-SoC pre-layout power review."""
from pathlib import Path
import argparse,subprocess,json,re,hashlib,os
from decimal import Decimal
from datetime import datetime,timezone
P=Path(__file__).resolve().parents[1]
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
 return h.hexdigest()
def t(p):
 s=str(p);assert not any(c in s for c in '{}\n\r');return '{'+s+'}'
ap=argparse.ArgumentParser();ap.add_argument('--mapped',type=Path,required=True);ap.add_argument('--simulation',type=Path,required=True)
a=ap.parse_args();mapped=a.mapped.resolve();sim=a.simulation.resolve()
mr=json.loads((mapped/'report.json').read_text());sr=json.loads((sim/'report.json').read_text())
assert mr['status']=='mapped_review_required'
assert all(r['passed'] for r in sr['layers']) and sr['macros']
captures=list(sim.glob('L*.vcd'));assert len(captures)==1
vcd=captures[0];start=end=None;stamp=0;scale=None
print('READ_WINDOW',vcd,flush=True)
with vcd.open('rb') as f:
 header=f.read(4096);match=re.search(rb'\$timescale\s+(\d+)\s*(fs|ps|ns|us|ms|s)',header)
 assert match;scale=(int(match[1]),match[2].decode())
 # C grep scans the large VCD without creating a Python object for every value change.
 hits=subprocess.check_output(['grep','-a','-b','-E',r'^\$(dumpon|dumpoff)',str(vcd)])
 events=[]
 for hit in hits.splitlines():
  offset,marker=hit.split(b':',1);offset=int(offset);size=65536
  while True:
   pos=max(0,offset-size);f.seek(pos);block=f.read(offset-pos)
   stamps=list(re.finditer(rb'(?m)^#([0-9]+)\r?$',block))
   if stamps:stamp=int(stamps[-1][1]);break
   assert pos>0,'No timestamp before dump control'
   size*=2
  events.append((marker,stamp))
 ons=[tick for marker,tick in events if marker.startswith(b'$dumpon')]
 offs=[tick for marker,tick in events if marker.startswith(b'$dumpoff')]
 offs=[tick for tick in offs if ons and tick>ons[0]]
 assert len(ons)==len(offs)==1,events
 start,end=ons[0],offs[0]
assert start is not None and end is not None and end>start
out=P/'sim/results'/('sysbus_power_'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'));out.mkdir(parents=True)
saif=out/'soc.saif'
command=['/eda/synopsys/prime/prime_2022.03-SP5-1/bin/vcd2saif','-input',str(vcd),'-output',str(saif),'-time',str(start),str(end)]
print('CONVERT',out,'ticks',start,end,'scale',scale,flush=True)
with (out/'conversion.log').open('wb') as log:subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True)
head=saif.open().read(65536);ss=re.search(r'\(TIMESCALE\s+(\S+)\s+(\w+)\)',head);duration=re.search(r'\(DURATION\s+(\d+)\)',head)
factors={'fs':Decimal('1e-6'),'ps':Decimal('.001'),'ns':Decimal(1),'us':Decimal(1000),'ms':Decimal(1000000),'s':Decimal(1000000000)}
expected=Decimal(end-start)*scale[0]*factors[scale[1]]
actual=Decimal(duration[1])*Decimal(ss[1])*factors[ss[2]];assert actual==expected,(actual,expected)
script=out/'power.tcl'
script.write_text('\n'.join([
 'source '+t(mapped/'config.tcl'),
 'set_app_var target_library [list $std_db]',
 'set_app_var link_library [concat [list * $std_db $rom_db] $sram_dbs]',
 'foreach db [concat [list $std_db $rom_db] $sram_dbs] { read_db $db }',
 'read_ddc '+t(mapped/'soc.ddc'),'current_design e203_soc_top','link',
 'read_saif -input '+t(saif)+' -instance_name tb_top/u_e203_soc_top',
 'redirect -file '+t(out/'activity.rpt')+' { report_saif -hierarchy }',
 'redirect -file '+t(out/'power.rpt')+' { report_power -hierarchy }',
 'redirect -file '+t(out/'power_verbose.rpt')+' { report_power -verbose }',
 'puts "SYSBUS_POWER_FINISHED"','exit'])+'\n')
print('POWER_REVIEW',out,flush=True)
with (out/'dc.log').open('wb') as log:
 rc=subprocess.run(['/eda/synopsys/dc/dc_2022.03-SP5-5/bin/dc_shell','-no_home_init','-f',str(script)],cwd=P,stdout=log,stderr=subprocess.STDOUT).returncode
logs=(out/'dc.log').read_text(errors='replace')+'\n'+'\n'.join(f.read_text(errors='replace') for f in out.glob('*.rpt'))
errors=[s for s in logs.splitlines() if s.lstrip().startswith('Error:')]
report={'status':'completed_review_required' if rc==0 and not errors else 'failed','errors':errors,
 'mapped':str(mapped),'simulation':str(sim),'activity_kind':'mapped' if sr.get('mapped') else 'RTL',
 'capture_ticks':[start,end],'duration_ns':str(actual),'ddc_sha256':sha(mapped/'soc.ddc'),'saif_sha256':sha(saif),
 'limitations':['selected layer only','functional models; no SDF or routed parasitics','annotation and macro power coverage require review'],'ppa_accepted':False}
(out/'report.json').write_text(json.dumps(report,indent=2));print(report['status'],out,flush=True)
